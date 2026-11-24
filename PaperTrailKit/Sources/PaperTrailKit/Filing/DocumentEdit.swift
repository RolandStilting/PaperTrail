import Foundation

/// Rules for changing the details of a document that is already filed: whether the file must
/// move, what happens to its reminder, and which details are locked.
public enum DocumentEdit {
    // MARK: File

    /// True when the file already sits where `plan` would put it: the same folder, and the
    /// planned name or that name with a collision number (" (2)"), so an unchanged document
    /// keeps its file name.
    public static func isAlreadyAt(_ relativePath: String, plan: FilingPlan) -> Bool {
        var components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let current = components.popLast() else { return false }
        guard components.map({ $0.lowercased() }) == plan.folderComponents.map({ $0.lowercased() }) else { return false }
        return isPlannedName(current, planned: plan.fileName)
    }

    /// "Name.pdf" or "Name (2).pdf" … "Name (999).pdf" for the planned "Name.pdf".
    static func isPlannedName(_ name: String, planned: String) -> Bool {
        let name = name.lowercased(), planned = planned.lowercased()
        if name == planned { return true }
        let (base, ext) = FileNamer.splitExtension(planned)
        let (currentBase, currentExt) = FileNamer.splitExtension(name)
        guard currentExt == ext, currentBase.hasPrefix(base + " ("), currentBase.hasSuffix(")") else { return false }
        let number = currentBase.dropFirst(base.count + 2).dropLast()
        guard let value = Int(number), String(value) == number else { return false }
        return (2...999).contains(value)
    }

    // MARK: Reminder

    /// What a bill's reminder shows; when any of it changes, the reminder is made again.
    public struct ReminderFacts: Equatable, Sendable {
        public var owner: String
        public var sender: String
        public var amount: Double?
        public var dueDate: Date?
        public var iban: String?
        public var reference: String?
        public var relativePath: String

        public init(owner: String, sender: String, amount: Double?, dueDate: Date?, iban: String?, reference: String?, relativePath: String) {
            self.owner = owner
            self.sender = sender
            self.amount = amount
            self.dueDate = dueDate
            self.iban = iban
            self.reference = reference
            self.relativePath = relativePath
        }
    }

    public enum ReminderChange: Equatable, Sendable {
        /// Leave the reminder as it is.
        case keep
        /// Add a reminder: the document became an unpaid bill.
        case create
        /// Make a new reminder (owner's list, title or notes changed) and remove the old one.
        case replace
        /// Remove the reminder: the document is no longer an unpaid bill.
        case remove
    }

    /// - Parameters:
    ///   - isPaid: A paid bill's reminder is completed and stays as it is.
    public static func reminderChange(before: ReminderFacts, after: ReminderFacts, wasUnpaidBill: Bool, isUnpaidBill: Bool,
                                      isPaid: Bool, hasReminder: Bool) -> ReminderChange {
        guard !isPaid else { return .keep }
        switch (wasUnpaidBill && hasReminder, isUnpaidBill) {
        case (false, true): return .create
        case (true, false): return .remove
        case (true, true): return before == after ? .keep : .replace
        case (false, false): return .keep
        }
    }

    // MARK: Locks

    /// A VAT return the user marked as submitted.
    public struct SubmittedReturn: Sendable {
        public var owner: String
        public var start: Date
        public var end: Date

        public init(owner: String, start: Date, end: Date) {
            self.owner = owner
            self.start = start
            self.end = end
        }
    }

    /// True when the document counts in a VAT return already submitted (for its owner, or the
    /// company that reimburses it). Its VAT, amount, date and owner then stay as submitted.
    public static func isInSubmittedVATReturn(owner: String, reimbursedBy: String?, vatDate: Date, returns: [SubmittedReturn]) -> Bool {
        returns.contains { ($0.owner == owner || $0.owner == reimbursedBy) && vatDate >= $0.start && vatDate < $0.end }
    }
}

extension DocumentRecord {
    public var reminderFacts: DocumentEdit.ReminderFacts {
        DocumentEdit.ReminderFacts(owner: ownerName, sender: sender, amount: amount, dueDate: dueDate,
                                   iban: iban, reference: paymentReference, relativePath: relativePath)
    }
}
