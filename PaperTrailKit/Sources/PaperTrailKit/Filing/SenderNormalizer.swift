import Foundation

/// Shortens a sender name to its core, e.g. "KPN B.V. Klantenservice" -> "KPN".
///
/// This is a simple heuristic: cut at the first legal-form token (B.V., GmbH, Ltd, ...)
/// that is not the first word. Learned sender rules (phase 2) refine this.
public enum SenderNormalizer {
    static let legalForms: Set<String> = [
        "b.v.", "bv", "n.v.", "nv", "v.o.f.", "vof", "c.v.", "cv",
        "gmbh", "ag", "kg", "ltd", "ltd.", "limited", "plc", "llc", "inc", "inc.",
        "s.a.", "sa", "s.a.r.l.", "sarl", "sas", "bvba", "s.p.a.", "spa", "ab", "as", "oy",
    ]

    public static func normalize(_ sender: String) -> String {
        let words = sender.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "" }
        var kept: [String] = []
        for (index, word) in words.enumerated() {
            let token = word.trimmingCharacters(in: CharacterSet(charactersIn: ",;")).lowercased()
            if index > 0, legalForms.contains(token) { break }
            kept.append(word)
        }
        return kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;-"))
    }
}
