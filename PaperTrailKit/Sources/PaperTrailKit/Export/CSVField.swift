import Foundation

/// One cell of the semicolon CSVs (index, VAT, expense claim).
///
/// Text from documents (sender, description, reference) can be chosen by whoever sent the
/// document. A cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage return is run as a
/// formula by Excel and Numbers ("CSV injection"), so such a cell gets a leading apostrophe and
/// is shown as text. Plain numbers such as `-12,50` stay numbers.
public enum CSVField {
    static let formulaStarts: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    public static func escape(_ text: String) -> String {
        var text = text
        if let first = text.first, formulaStarts.contains(first), !isPlainNumber(text) {
            text = "'" + text
        }
        let needsQuotes = text.contains(";") || text.contains("\"") || text.contains("\n") || text.contains("\r")
        return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    /// "-12,50", "+3.5", "-21%": a number as the exports write it, safe to leave as is.
    static func isPlainNumber(_ text: String) -> Bool {
        text.wholeMatch(of: /[-+]?[0-9]+([.,][0-9]+)?%?/) != nil
    }
}
