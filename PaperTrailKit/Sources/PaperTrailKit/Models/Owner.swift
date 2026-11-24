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

/// The colour that marks an owner in lists and the sidebar.
public enum OwnerColor: String, Codable, Hashable, Sendable, CaseIterable {
    case blue, teal, green, orange, red, pink, purple, gray

    /// Default colours for owners without a choice, by position in the list.
    public static func automatic(index: Int) -> OwnerColor {
        [.blue, .teal, .orange, .purple, .pink, .green, .red, .gray][index % 8]
    }
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
    /// nil: an automatic colour by position.
    public var color: OwnerColor?
    /// Whether this owner's banking app accepts the standard EPC payment QR code (ASN does,
    /// the Rabobank app doesn't). When false, only a code printed on the invoice is shown.
    public var bankScansEPCQRCode: Bool
    /// The owner's chart of accounts (optional): ledger codes for the admin department, offered
    /// for categories that use ledger codes. Most owners have none.
    public var ledgerCodes: [LedgerCode]
    /// Read from settings saved before codes were per owner; moved by ``ArchiveSettings``.
    var legacyLedgerLists: [LegacyLedgerCodeList] = []

    public init(id: UUID = UUID(), name: String, paymentMethod: PaymentMethod = .qrCode, payingAccount: PayingAccount = PayingAccount(),
                vatPeriod: VATPeriodKind? = nil, color: OwnerColor? = nil, bankScansEPCQRCode: Bool = true, ledgerCodes: [LedgerCode] = []) {
        self.id = id
        self.name = name
        self.paymentMethod = paymentMethod
        self.payingAccount = payingAccount
        self.vatPeriod = vatPeriod
        self.color = color
        self.bankScansEPCQRCode = bankScansEPCQRCode
        self.ledgerCodes = ledgerCodes
    }

    enum CodingKeys: String, CodingKey { case id, name, paymentMethod, payingAccount, vatPeriod, color, bankScansEPCQRCode, ledgerCodes, ledgerLists }

    /// Settings saved before phase 4 have no payment fields; they get the defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        paymentMethod = try container.decodeIfPresent(PaymentMethod.self, forKey: .paymentMethod) ?? .qrCode
        payingAccount = try container.decodeIfPresent(PayingAccount.self, forKey: .payingAccount) ?? PayingAccount()
        vatPeriod = try container.decodeIfPresent(VATPeriodKind.self, forKey: .vatPeriod)
        color = try container.decodeIfPresent(OwnerColor.self, forKey: .color)
        bankScansEPCQRCode = try container.decodeIfPresent(Bool.self, forKey: .bankScansEPCQRCode) ?? true
        ledgerCodes = try container.decodeIfPresent([LedgerCode].self, forKey: .ledgerCodes) ?? []
        legacyLedgerLists = try container.decodeIfPresent([LegacyLedgerCodeList].self, forKey: .ledgerLists) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(paymentMethod, forKey: .paymentMethod)
        try container.encode(payingAccount, forKey: .payingAccount)
        try container.encodeIfPresent(vatPeriod, forKey: .vatPeriod)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encode(bankScansEPCQRCode, forKey: .bankScansEPCQRCode)
        try container.encode(ledgerCodes, forKey: .ledgerCodes)
    }
}
