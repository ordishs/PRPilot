import SwiftUI
import AppKit
import WebKit
import PRPilotModels

struct WebPane: View {
    let cache: WebViewCache
    let review: WorkItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { cache.reload(for: review) }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: [.command])
                .help("Refresh (\u{2318}R)")

                Text(review.url?.absoluteString ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: { copyURL() }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy URL")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.05))

            LoadProgressBar(state: cache.loadState(for: review))

            Divider()

            WebViewHost(cache: cache, review: review)
        }
    }

    private func copyURL() {
        if let url = review.url {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}

/// Safari-style loading strip. The band is always laid out — only its fill and opacity
/// change — so starting or finishing a load never reflows the pane.
private struct LoadProgressBar: View {
    let state: WebLoadState

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: max(0, geometry.size.width * state.progress))
                .animation(.linear(duration: 0.15), value: state.progress)
        }
        .frame(height: 2)
        .opacity(state.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: state.isLoading)
    }
}

/// Reports when it lands in a window, which is the moment WebKit will actually
/// load a page at full speed.
private final class WebContainerView: NSView {
    var onEnterWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onEnterWindow?() }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let cache: WebViewCache
    let review: WorkItem

    func makeNSView(context: Context) -> NSView {
        let container = WebContainerView()
        let review = review
        let cache = cache
        container.onEnterWindow = { cache.activate(for: review) }
        let webView = cache.ensure(for: review)
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window != nil { cache.loadIfBlank(for: review) }
    }
}
