#if os(macOS)
import Foundation
import PaperTrailKit
import WebKit

nonisolated enum HTMLRenderError: LocalizedError {
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let reason):
            String(localized: "Could not turn the email into a PDF: \(reason) The email stays in the mailbox and is tried again.")
        }
    }
}

/// Turns an email's HTML into an A4-paged PDF. JavaScript is off and nothing is loaded from
/// the internet (no tracking pixels, no remote images); only content inside the email shows.
@MainActor
final class HTMLPDFRenderer: NSObject, WKNavigationDelegate {
    /// A typical HTML email is 600–640 px wide; pages keep A4 proportions at that width.
    static let width: CGFloat = 640
    /// Content blocker regexes don't support alternatives, so one rule per scheme.
    static let blockRemoteContent = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#

    private var continuation: CheckedContinuation<Void, Error>?

    func pdf(html: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let rules: WKContentRuleList? = try await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "PaperTrailBlockRemoteContent", encodedContentRuleList: Self.blockRemoteContent)
        if let rules { configuration.userContentController.add(rules) }

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
        let tall = try await webView.pdf(configuration: WKPDFConfiguration())
        return try PDFPaginator.paginate(tall, pageHeight: Self.width * PDFPaginator.a4Height / PDFBuilder.pageWidth)
    }

    /// Plain-text emails are shown as preformatted text.
    func pdf(text: String) async throws -> Data {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return try await pdf(html: "<html><body style=\"font: 13px -apple-system, Helvetica; margin: 32px\"><pre style=\"white-space: pre-wrap; font: inherit\">\(escaped)</pre></body></html>")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: HTMLRenderError.loadFailed(error.localizedDescription))
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: HTMLRenderError.loadFailed(error.localizedDescription))
        continuation = nil
    }

    /// Only the email itself loads; links and redirects are never followed.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.navigationType == .other && (navigationAction.request.url?.scheme ?? "about") == "about" ? .allow : .cancel
    }
}
#endif
