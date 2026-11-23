import Foundation
import FoundationModels

/// What the on-device model fills in for one document (guided generation).
/// Dates are strings so a malformed date fails softly instead of failing generation.
@Generable
public struct ModelExtraction: Sendable, Equatable {
    @Guide(description: "Short name of the organisation or person that sent the document, without legal forms such as B.V., N.V., GmbH, Ltd or Inc, and without department names. For example \"Acme Energie\", not \"Acme Energie B.V. Klantenservice\".")
    public var sender: String

    @Guide(description: "The date printed on the document as yyyy-MM-dd, for example the invoice date or letter date. Empty if there is none.")
    public var documentDate: String

    @Guide(description: "Exactly one of the category names listed in the instructions.")
    public var category: String

    @Guide(description: "What the document is, in at most 6 words, in the language of the document. Do not repeat the sender. For example \"Energierekening maart 2026\" or \"Hotel receipt Berlin\".")
    public var description: String

    @Guide(description: "True only if the document asks the recipient to pay an amount that has not been paid yet. False for receipts, paid invoices, direct debits that are collected automatically, and letters.")
    public var isUnpaidBill: Bool

    @Guide(description: "Total amount to pay or paid, in euros, as a number with a dot as decimal separator, for example 123.45. 0 if there is no amount.")
    public var amount: Double

    @Guide(description: "Payment due date as yyyy-MM-dd. Empty if there is none.")
    public var dueDate: String

    @Guide(description: "IBAN to pay to, without spaces. Empty if there is none.")
    public var iban: String

    @Guide(description: "Invoice number, payment reference or 'betalingskenmerk'. Empty if there is none.")
    public var reference: String
}

public enum ExtractionPrompt {
    /// Characters of OCR text sent to the model. The on-device context window is small,
    /// and the header of a document holds most of what we need.
    public static let maxTextLength = 6_000

    public static func instructions(categories: [String]) -> String {
        """
        You read the text of a scanned or digital document (receipt, invoice, letter, contract, policy, tax assessment) \
        that a person received, and extract filing details. Documents are usually in Dutch or English. \
        Only use information that is in the text; never invent values. \
        The recipient is the person who received the document; the sender is the organisation that wrote it. \
        Choose the category from this list:
        \(CategoryHints.describe(categories))
        """
    }

    public static func prompt(for text: String) -> String {
        "Document text:\n\n\(text.prefix(maxTextLength))"
    }
}

public enum ModelAvailability: Equatable, Sendable {
    case available
    case unavailable(ModelUnavailableReason)
}

/// Why the on-device model can't run, mirroring `SystemLanguageModel.Availability.UnavailableReason`.
public enum ModelUnavailableReason: Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// A reason added in a later OS version.
    case other(String)

    /// What went wrong and what the user can do, shown in the filing screen.
    public var message: String {
        switch self {
        case .deviceNotEligible:
            String(localized: "This device doesn't support Apple Intelligence, so Paper Trail can't suggest details here. Fill them in yourself.", bundle: .module)
        case .appleIntelligenceNotEnabled:
            String(localized: "Apple Intelligence is turned off. To get suggestions, turn it on in (System) Settings → Apple Intelligence & Siri. The device language and the Siri language must be the same supported language.", bundle: .module)
        case .modelNotReady:
            String(localized: "Apple Intelligence is still getting ready, for example downloading its model. Keep the device on Wi-Fi and power, and try again later.", bundle: .module)
        case .other(let reason):
            String(localized: "Apple Intelligence is not available right now (\(reason)). Fill in the details yourself.", bundle: .module)
        }
    }
}

/// Runs the on-device model. Document text never leaves the device.
public struct ModelExtractor: Sendable {
    public var categories: [String]

    public init(categories: [String]) {
        self.categories = categories
    }

    public static var availability: ModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .unavailable(.deviceNotEligible)
        case .unavailable(.appleIntelligenceNotEnabled): .unavailable(.appleIntelligenceNotEnabled)
        case .unavailable(.modelNotReady): .unavailable(.modelNotReady)
        case .unavailable(let reason): .unavailable(.other(String(describing: reason)))
        }
    }

    public func extract(from text: String) async throws -> ModelExtraction {
        let session = LanguageModelSession(instructions: ExtractionPrompt.instructions(categories: categories))
        let response = try await session.respond(
            to: ExtractionPrompt.prompt(for: text),
            generating: ModelExtraction.self,
            options: GenerationOptions(samplingMode: .greedy)
        )
        return response.content
    }

    /// The model's answer, corrected by ``ExtractionChecks`` against the text.
    public func propose(from text: String) async throws -> ModelExtraction {
        ExtractionChecks.apply(try await extract(from: text), text: text, categories: categories)
    }
}
