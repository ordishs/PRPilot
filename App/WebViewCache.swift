import AppKit
import AppCore
import SwiftUI
import WebKit
import PRPilotModels

/// Tracks whether a web view's current document actually finished loading, so a
/// half-finished page can be re-driven instead of being displayed as-is.
@MainActor
final class LoadTracker: NSObject, WKNavigationDelegate {
    private(set) var didFinishLoad = false
    var onProcessTerminated: (() -> Void)?
    /// Reports every transition so the cache can publish it to the progress bar.
    var onLoadState: ((WebLoadState) -> Void)?
    /// Retains the KVO registration on `estimatedProgress` for this web view's lifetime.
    var progressObservation: NSKeyValueObservation?
    private var loadState = WebLoadState()

    private func publish() {
        onLoadState?(loadState)
    }

    func progressed(to value: Double) {
        loadState.progressed(to: value)
        publish()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        didFinishLoad = false
        loadState.started()
        publish()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoad = true
        loadState.finished()
        publish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        didFinishLoad = false
        loadState.failed()
        publish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        didFinishLoad = false
        loadState.failed()
        publish()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        didFinishLoad = false
        loadState.failed()
        publish()
        onProcessTerminated?()
    }
}

@MainActor
@Observable
final class WebViewCache {
    private var webViews: [String: WKWebView] = [:]
    private var trackers: [String: LoadTracker] = [:]
    /// Per-item load progress, driving the GitHub pane's progress bar.
    private(set) var loadStates: [String: WebLoadState] = [:]
    private let configuration: WKWebViewConfiguration
    /// Item ids, most recently activated first. Drives eviction.
    private var activationOrder: [String] = []
    /// Mirrors `Settings.maxLiveWebViews`. `ContentView` keeps it in step.
    var cap: Int = 8
    /// The selected item is never evicted. `ContentView` keeps it in step.
    var selectedID: String?

    init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.addUserScript(Self.hideChromeScript)
        config.userContentController = controller
        self.configuration = config
    }

    // Hides GitHub's global navigation bar and the repository tab row
    // (Code / Issues / Pull requests / …) so the embedded view stays focused on
    // the PR and the user can't wander off. The PR's own sub-tabs (Conversation,
    // Commits, Files changed) live outside these containers and are preserved.
    // Selectors track GitHub's current markup and may need updating if it changes.
    private static let hideChromeCSS = """
    .AppHeader,
    header[role="banner"],
    #repository-container-header,
    nav[aria-label="Repository"] { display: none !important; }
    """

    private static let hideChromeScript: WKUserScript = {
        let source = """
        (function() {
          var style = document.createElement('style');
          style.textContent = `\(hideChromeCSS)`;
          (document.head || document.documentElement).appendChild(style);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    /// Returns the web view for an item, creating it if needed. Deliberately does
    /// *not* start loading: WebKit treats a page whose view has no window as
    /// hidden and throttles its resource loading to a crawl, so a page started
    /// here sits half-parsed — stylesheets fetched but not applied — and paints
    /// blank or as unstyled HTML when it is finally shown. Loading happens in
    /// `activate(for:)`, once the view is actually on screen.
    func ensure(for review: WorkItem) -> WKWebView {
        if let existing = webViews[review.id] { return existing }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let tracker = LoadTracker()
        tracker.onProcessTerminated = { [weak webView] in
            guard let webView, webView.window != nil, let url = review.url else { return }
            webView.load(URLRequest(url: url))
        }
        tracker.onLoadState = { [weak self] state in
            self?.loadStates[review.id] = state
        }
        // estimatedProgress is the only source of intermediate progress; the delegate
        // callbacks alone would give a bar that jumps straight from 0 to done. KVO for it
        // fires on the main thread, since WKWebView is main-thread-only.
        tracker.progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak tracker] webView, _ in
            MainActor.assumeIsolated {
                tracker?.progressed(to: webView.estimatedProgress)
            }
        }
        webView.navigationDelegate = tracker
        webViews[review.id] = webView
        trackers[review.id] = tracker
        return webView
    }

    /// Called when an item's web view enters a window. Starts the load if the page
    /// isn't already loaded or loading — which also recovers a view whose earlier
    /// load failed or whose web content process was killed.
    func activate(for review: WorkItem) {
        recordActivation(review.id)
        enforceBudget()
        guard let url = review.url, let webView = webViews[review.id] else { return }
        if webView.isLoading { return }
        // All webviews share the persistent .default() cookie store, so a session
        // established in one tab is visible to the rest. A tab that loaded while
        // signed out stays on the login page until reloaded — refresh it on
        // revisit so it picks up the now-present session.
        let landedOnLogin = Self.isGitHubAuthPage(webView.url)
        if trackers[review.id]?.didFinishLoad == true && !landedOnLogin { return }
        webView.load(URLRequest(url: url))
    }

    private func recordActivation(_ id: String) {
        activationOrder.removeAll { $0 == id }
        activationOrder.insert(id, at: 0)
    }

    private func enforceBudget() {
        let victims = WebViewBudget.evictions(
            activationOrder: activationOrder,
            cap: cap,
            selectedID: selectedID
        )
        for id in victims {
            remove(reviewID: id)
        }
    }

    /// Safety net for a view that is on screen with nothing loaded at all. Called
    /// on every SwiftUI update, so it must never re-drive a page that merely
    /// finished on GitHub's login screen — that would reload in a loop.
    func loadIfBlank(for review: WorkItem) {
        guard let url = review.url, let webView = webViews[review.id] else { return }
        guard webView.url == nil, !webView.isLoading else { return }
        webView.load(URLRequest(url: url))
    }

    private static func isGitHubAuthPage(_ url: URL?) -> Bool {
        guard let url, (url.host ?? "").contains("github.com") else { return false }
        return url.path.hasPrefix("/login") || url.path.hasPrefix("/session")
    }

    func reload(for review: WorkItem) {
        webViews[review.id]?.reload()
    }

    func loadState(for review: WorkItem) -> WebLoadState {
        loadStates[review.id] ?? WebLoadState()
    }

    /// Whether this item currently holds a web view. The sidebar shows it, because a live
    /// view holds its own WebContent process and the cap makes them a scarce resource.
    func isLive(_ reviewID: String) -> Bool {
        webViews[reviewID] != nil
    }

    func remove(reviewID: String) {
        activationOrder.removeAll { $0 == reviewID }
        trackers.removeValue(forKey: reviewID)?.progressObservation?.invalidate()
        loadStates.removeValue(forKey: reviewID)
        if let webView = webViews.removeValue(forKey: reviewID) {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
    }

    func removeAll() {
        activationOrder.removeAll()
        for tracker in trackers.values { tracker.progressObservation?.invalidate() }
        trackers.removeAll()
        loadStates.removeAll()
        for webView in webViews.values {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webViews.removeAll()
    }
}
