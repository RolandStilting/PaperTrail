import Foundation

/// Prepares an email's HTML for turning into a PDF. The web view already runs no JavaScript and
/// blocks remote loads; this also removes what could still reach out or redirect (link hints
/// such as preconnect and DNS prefetch, a base URL, meta refresh) and adds a strict content
/// security policy, so opening the email can't tell the sender anything.
public enum EmailHTML {
    static let policy = "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline' data:; font-src data:; media-src 'none'; frame-src 'none'; form-action 'none'"

    public static func hardened(_ html: String) -> String {
        var html = html
        let patterns = [
            #"<link\b[^>]*>"#,
            #"<base\b[^>]*>"#,
            #"<meta\b[^>]*http-equiv\s*=\s*["']?\s*(refresh|content-security-policy|x-dns-prefetch-control)[^>]*>"#,
        ]
        for pattern in patterns {
            html = html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let head = """
        <meta http-equiv="Content-Security-Policy" content="\(policy)">\
        <meta http-equiv="x-dns-prefetch-control" content="off">
        """
        return head + html
    }
}
