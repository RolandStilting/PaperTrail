import Foundation
import FoundationModels

/// The on-device model's choice of ledger code for one document.
@Generable
public struct LedgerCodeAnswer: Sendable, Equatable {
    @Guide(description: "Exactly one code from the list in the instructions, only the code itself, for example \"4300\". Empty if no code fits.")
    public var code: String
}

/// Builds the request for a ledger code suggestion and checks the answer against the list.
/// Used when no learned rule knows a code for the sender, owner and category.
public enum LedgerSuggestion {
    /// Characters of code list and document text sent to the model. The on-device context
    /// window is small; the extraction prompt uses more text, this one needs room for the list.
    public static let maxListLength = 2_500
    public static let maxTextLength = 2_500

    /// The codes as "- code: description" lines, as many as fit in `maxListLength`.
    public static func describe(_ codes: [LedgerCode], maxLength: Int = maxListLength) -> String {
        var lines: [String] = []
        var length = 0
        for code in codes where !code.code.isEmpty {
            let line = code.description.isEmpty ? "- \(code.code)" : "- \(code.code): \(code.description)"
            guard length + line.count + 1 <= maxLength else { break }
            lines.append(line)
            length += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    public static func instructions(codes: [LedgerCode], category: String) -> String {
        """
        You help a bookkeeper. Given the text of a document filed as "\(category)", choose the ledger account \
        (grootboekrekening) it should be booked on, based on what was bought or what the document is about. \
        Documents are usually in Dutch or English. Choose exactly one code from this list, or leave the code \
        empty if none clearly fits:
        \(describe(codes))
        """
    }

    public static func prompt(sender: String, description: String, text: String) -> String {
        var lines: [String] = []
        if !sender.isEmpty { lines.append("Sender: \(sender)") }
        if !description.isEmpty { lines.append("Description: \(description)") }
        lines.append("Document text:\n\n\(text.prefix(maxTextLength))")
        return lines.joined(separator: "\n")
    }

    /// The code in `codes` that the model's answer means: the code itself (any case), a code
    /// followed by its description ("4300 – Telefoon"), or a description alone. nil when the
    /// answer is empty or not in the list; the model must never add a code of its own.
    public static func match(_ answer: String, in codes: [LedgerCode]) -> LedgerCode? {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'`-")))
        guard !answer.isEmpty else { return nil }
        if let exact = codes.first(where: { $0.matches(answer) }) { return exact }
        let lowered = answer.lowercased()
        let prefixed = codes
            .filter { code in
                let key = LedgerCode.key(code.code)
                guard !key.isEmpty, lowered.hasPrefix(key) else { return false }
                let next = lowered.dropFirst(key.count).first
                return next.map { !($0.isLetter || $0.isNumber) } ?? true
            }
            .max { $0.code.count < $1.code.count }
        if let prefixed { return prefixed }
        return codes.first { !$0.description.isEmpty && $0.description.lowercased() == lowered }
    }
}

/// Runs the on-device model for a ledger code. Document text never leaves the device.
public struct LedgerCodeSuggester: Sendable {
    public var codes: [LedgerCode]
    public var category: String

    public init(codes: [LedgerCode], category: String) {
        self.codes = codes
        self.category = category
    }

    /// The suggested code, or nil when the model finds none in the list.
    public func suggest(sender: String, description: String, text: String) async throws -> LedgerCode? {
        guard !codes.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: LedgerSuggestion.instructions(codes: codes, category: category))
        let response = try await session.respond(
            to: LedgerSuggestion.prompt(sender: sender, description: description, text: text),
            generating: LedgerCodeAnswer.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return LedgerSuggestion.match(response.content.code, in: codes)
    }
}
