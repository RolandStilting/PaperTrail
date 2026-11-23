import Foundation

/// One payment in a SEPA batch.
public struct SEPAPayment: Sendable, Hashable {
    public var creditorName: String
    public var creditorIBAN: String
    public var creditorBIC: String
    public var amount: Double
    /// Betalingskenmerk, RF creditor reference or free text.
    public var reference: String
    /// Unique per payment; the bank passes it to the creditor. Max 35 characters.
    public var endToEndID: String

    public init(creditorName: String, creditorIBAN: String, creditorBIC: String = "", amount: Double, reference: String, endToEndID: String) {
        self.creditorName = creditorName
        self.creditorIBAN = creditorIBAN
        self.creditorBIC = creditorBIC
        self.amount = amount
        self.reference = reference
        self.endToEndID = endToEndID
    }
}

/// Builds a SEPA credit transfer batch file (ISO 20022 pain.001.001.03) to upload in
/// business internet banking. The bank shows every payment for checking before signing;
/// nothing is paid by creating the file.
///
/// Version .001.001.03 is one of the versions Rabobank documents. Check the bank's current
/// format specification before relying on it, and test a first file without signing it.
public enum SEPACreditTransfer {
    public static let namespace = "urn:iso:std:iso:20022:tech:xsd:pain.001.001.03"

    public enum ValidationError: Error, Equatable, Sendable {
        case noPayments
        case missingDebtor
        case invalidDebtorIBAN
        case invalidCreditorIBAN(String)
        case missingCreditorName(String)
        case invalidAmount(String)
    }

    /// Problems with one payment, if any. Use it to leave unusable bills out of a batch.
    public static func problem(with payment: SEPAPayment) -> ValidationError? {
        if sanitize(payment.creditorName, maxLength: 70).isEmpty { return .missingCreditorName(payment.endToEndID) }
        if !IBAN.isValid(payment.creditorIBAN) { return .invalidCreditorIBAN(payment.endToEndID) }
        if !(0.01...999_999_999.99).contains(payment.amount) { return .invalidAmount(payment.endToEndID) }
        return nil
    }

    public static func xml(messageID: String, created: Date, executionDate: Date, debtor: PayingAccount,
                           payments: [SEPAPayment], calendar: Calendar? = nil) throws(ValidationError) -> String {
        guard !payments.isEmpty else { throw .noPayments }
        let debtorName = sanitize(debtor.name, maxLength: 70)
        guard !debtorName.isEmpty else { throw .missingDebtor }
        guard IBAN.isValid(debtor.iban) else { throw .invalidDebtorIBAN }
        for payment in payments {
            if let problem = problem(with: payment) { throw problem }
        }
        let calendar = calendar ?? FileNamer.defaultCalendar()

        let cents = payments.map { Int(($0.amount * 100).rounded()) }
        let controlSum = amountText(cents: cents.reduce(0, +))
        let messageID = sanitize(messageID, maxLength: 35)
        let debtorBIC = IBAN.normalize(debtor.bic)

        let transactions: [XMLNode] = zip(payments, cents).map { payment, amountCents in
            let bic = IBAN.normalize(payment.creditorBIC)
            var children: [XMLNode] = [
                .element("PmtId", [.leaf("EndToEndId", sanitize(payment.endToEndID, maxLength: 35))]),
                .element("Amt", [.leaf("InstdAmt", amountText(cents: amountCents), attributes: "Ccy=\"EUR\"")]),
            ]
            if !bic.isEmpty {
                children.append(.element("CdtrAgt", [.element("FinInstnId", [.leaf("BIC", bic)])]))
            }
            children.append(.element("Cdtr", [.leaf("Nm", sanitize(payment.creditorName, maxLength: 70))]))
            children.append(.element("CdtrAcct", [.element("Id", [.leaf("IBAN", IBAN.normalize(payment.creditorIBAN))])]))
            if let remittance = remittance(payment.reference) { children.append(remittance) }
            return .element("CdtTrfTxInf", children)
        }

        let paymentInfo: [XMLNode] = [
            .leaf("PmtInfId", messageID),
            .leaf("PmtMtd", "TRF"),
            .leaf("NbOfTxs", String(payments.count)),
            .leaf("CtrlSum", controlSum),
            .element("PmtTpInf", [.element("SvcLvl", [.leaf("Cd", "SEPA")])]),
            .leaf("ReqdExctnDt", date(executionDate, calendar: calendar)),
            .element("Dbtr", [.leaf("Nm", debtorName)]),
            .element("DbtrAcct", [.element("Id", [.leaf("IBAN", IBAN.normalize(debtor.iban))])]),
            .element("DbtrAgt", [.element("FinInstnId", [
                debtorBIC.isEmpty ? .element("Othr", [.leaf("Id", "NOTPROVIDED")]) : .leaf("BIC", debtorBIC),
            ])]),
            .leaf("ChrgBr", "SLEV"),
        ] + transactions

        let document = XMLNode.element("Document", attributes: "xmlns=\"\(namespace)\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"", [
            .element("CstmrCdtTrfInitn", [
                .element("GrpHdr", [
                    .leaf("MsgId", messageID),
                    .leaf("CreDtTm", dateTime(created, calendar: calendar)),
                    .leaf("NbOfTxs", String(payments.count)),
                    .leaf("CtrlSum", controlSum),
                    .element("InitgPty", [.leaf("Nm", debtorName)]),
                ]),
                .element("PmtInf", paymentInfo),
            ]),
        ])
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + document.render()
    }

    /// A Dutch betalingskenmerk (16 digits) or an RF creditor reference goes in the structured
    /// field, so the creditor can match the payment; anything else is free text.
    static func remittance(_ reference: String) -> XMLNode? {
        let compact = reference.filter { !$0.isWhitespace }
        if compact.count == 16, compact.allSatisfy(\.isNumber) {
            return structured(compact, issuer: "CUR")
        }
        if compact.uppercased().hasPrefix("RF"), compact.count <= 25, compact.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return structured(compact.uppercased(), issuer: "ISO")
        }
        let text = sanitize(reference, maxLength: 140)
        return text.isEmpty ? nil : .element("RmtInf", [.leaf("Ustrd", text)])
    }

    private static func structured(_ reference: String, issuer: String) -> XMLNode {
        .element("RmtInf", [.element("Strd", [.element("CdtrRefInf", [
            .element("Tp", [.element("CdOrPrtry", [.leaf("Cd", "SCOR")]), .leaf("Issr", issuer)]),
            .leaf("Ref", reference),
        ])])])
    }

    /// SEPA allows a limited Latin character set. Accents are removed and anything else
    /// becomes a space: a-z A-Z 0-9 / - ? : ( ) . , ' + and space remain.
    static func sanitize(_ text: String, maxLength: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-?:().,'+ ")
        let plain = text.applyingTransform(.stripDiacritics, reverse: false) ?? text
        let mapped = String(plain.map { allowed.contains($0) ? $0 : " " })
        let collapsed = mapped.split(separator: " ").joined(separator: " ")
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    static func amountText(cents: Int) -> String {
        String(format: "%d.%02d", cents / 100, cents % 100)
    }

    static func date(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func dateTime(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}

/// A small XML tree, rendered with two-space indentation. Values are escaped.
indirect enum XMLNode: Sendable {
    case tag(String, attributes: String?, [XMLNode])
    case leaf(String, String, attributes: String? = nil)

    static func element(_ name: String, attributes: String? = nil, _ children: [XMLNode]) -> XMLNode {
        .tag(name, attributes: attributes, children)
    }

    func render(depth: Int = 0) -> String {
        let indent = String(repeating: "  ", count: depth)
        switch self {
        case .tag(let name, let attributes, let children):
            let open = attributes.map { "\(name) \($0)" } ?? name
            return "\(indent)<\(open)>\n" + children.map { $0.render(depth: depth + 1) }.joined() + "\(indent)</\(name)>\n"
        case .leaf(let name, let value, let attributes):
            let open = attributes.map { "\(name) \($0)" } ?? name
            return "\(indent)<\(open)>\(Self.escape(value))</\(name)>\n"
        }
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
