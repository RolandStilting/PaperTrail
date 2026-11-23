import Foundation

/// How bills for an owner are paid. Paper Trail never sends payments itself.
public enum PaymentMethod: String, Codable, Hashable, Sendable, CaseIterable {
    /// EPC QR code and copy buttons, to pay in a banking app.
    case qrCode
    /// A SEPA batch file (pain.001) to upload in business internet banking.
    case sepaFile
}

/// The account an owner pays from. Needed for SEPA files; stored with the other settings.
public struct PayingAccount: Codable, Hashable, Sendable {
    public var name: String
    /// Without spaces.
    public var iban: String
    public var bic: String

    public init(name: String = "", iban: String = "", bic: String = "") {
        self.name = name
        self.iban = iban
        self.bic = bic
    }

    public var isEmpty: Bool { name.isEmpty && iban.isEmpty && bic.isEmpty }
}

/// A person or company that documents are filed for, e.g. "Private" or a company name.
/// Each owner gets its own top-level folder in the archive and its own "To pay" list.
public struct Owner: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var paymentMethod: PaymentMethod
    public var payingAccount: PayingAccount
    /// How often this owner files a VAT return; nil when it doesn't (e.g. Private).
    public var vatPeriod: VATPeriodKind?

    public init(id: UUID = UUID(), name: String, paymentMethod: PaymentMethod = .qrCode, payingAccount: PayingAccount = PayingAccount(),
                vatPeriod: VATPeriodKind? = nil) {
        self.id = id
        self.name = name
        self.paymentMethod = paymentMethod
        self.payingAccount = payingAccount
        self.vatPeriod = vatPeriod
    }

    enum CodingKeys: String, CodingKey { case id, name, paymentMethod, payingAccount, vatPeriod }

    /// Settings saved before phase 4 have no payment fields; they get the defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        paymentMethod = try container.decodeIfPresent(PaymentMethod.self, forKey: .paymentMethod) ?? .qrCode
        payingAccount = try container.decodeIfPresent(PayingAccount.self, forKey: .payingAccount) ?? PayingAccount()
        vatPeriod = try container.decodeIfPresent(VATPeriodKind.self, forKey: .vatPeriod)
    }
}
