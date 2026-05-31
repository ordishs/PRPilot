import AppKit
import SwiftUI
import WebKit
import PRReviewModels

@MainActor
@Observable
final class WebViewCache {
    private var webViews: [String: WKWebView] = [:]
    private let configuration: WKWebViewConfiguration

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

    func ensure(for review: Review) -> WKWebView {
        if let existing = webViews[review.id] {
            // All webviews share the persistent .default() cookie store, so a
            // session established in one tab is visible to the rest. A tab that
            // loaded while signed out stays on the login page until reloaded —
            // refresh it on revisit so it picks up the now-present session.
            if Self.isGitHubAuthPage(existing.url) {
                existing.load(URLRequest(url: review.url))
            }
            return existing
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.load(URLRequest(url: review.url))
        webViews[review.id] = webView
        return webView
    }

    private static func isGitHubAuthPage(_ url: URL?) -> Bool {
        guard let url, (url.host ?? "").contains("github.com") else { return false }
        return url.path.hasPrefix("/login") || url.path.hasPrefix("/session")
    }

    func reload(for review: Review) {
        webViews[review.id]?.reload()
    }

    func remove(reviewID: String) {
        if let webView = webViews.removeValue(forKey: reviewID) {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
    }

    func removeAll() {
        for webView in webViews.values {
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        webViews.removeAll()
    }
}
