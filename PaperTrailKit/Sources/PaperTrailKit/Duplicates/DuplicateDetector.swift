import Foundation

/// The facts about one document that duplicate detection compares.
public struct DuplicateFacts: Sendable, Hashable {
    public var id: UUID
    public var relativePath: String
    /// SHA-256 of the PDF bytes, hex encoded.
    public var contentHash: String?
    public var sender: String
    public var amount: Double?
    /// Invoice number or payment reference.
    public var reference: String?
    public var documentDate: Date?
    public var receivedDate: Date
    public var filedAt: Date

    public init(id: UUID = UUID(), relativePath: String = "", contentHash: String? = nil, sender: String, amount: Double? = nil,
                reference: String? = nil, documentDate: Date? = nil, receivedDate: Date, filedAt: Date = .now) {
        self.id = id
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.sender = sender
        self.amount = amount
        self.reference = reference
        self.documentDate = documentDate
        self.receivedDate = receivedDate
        self.filedAt = filedAt
    }
}

public struct DuplicateMatch: Sendable, Hashable {
    public enum Reason: Int, Sendable, Hashable, Comparable {
        /// The PDF is byte for byte the same.
        case sameFile = 0
        /// Same sender and same invoice number or payment reference.
        case sameReference = 1
        /// Same sender, same amount, same date.
        case sameSenderAmountAndDate = 2

        public static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Explanation for the warning in the filing screen.
        public var message: String {
            switch self {
            case .sameFile:
                String(localized: "This is exactly the same file.", bundle: .module)
            case .sameReference:
                String(localized: "Same sender and the same invoice number or reference.", bundle: .module)
            case .sameSenderAmountAndDate:
                String(localized: "Same sender, amount and date.", bundle: .module)
            }
        }
    }

    public var existing: DuplicateFacts
    public var reason: Reason
}

/// Finds documents in the index that are probably the same as a new one, for example the
/// same bill received by post and by email. The user decides; this only warns.
public enum DuplicateDetector {
    /// References shorter than this ("1", "12") are too common to mean anything.
    static let minimumReferenceLength = 4
    /// Without a date on both documents, received dates this close count as the same date.
    static let receivedDateTolerance: TimeInterval = 7 * 24 * 60 * 60

    static func senderKey(_ sender: String) -> String {
        SenderNormalizer.normalize(sender).lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func referenceKey(_ reference: String?) -> String {
        (reference ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Matches, strongest reason first, then most recently filed. At most one match per document.
    public static func matches(for candidate: DuplicateFacts, in existing: [DuplicateFacts], calendar: Calendar? = nil) -> [DuplicateMatch] {
        let calendar = calendar ?? FileNamer.defaultCalendar()
        let sender = senderKey(candidate.sender)
        let reference = referenceKey(candidate.reference)

        let found: [DuplicateMatch] = existing.compactMap { other in
            guard other.id != candidate.id else { return nil }
            if let hash = candidate.contentHash, !hash.isEmpty, hash == other.contentHash {
                return DuplicateMatch(existing: other, reason: .sameFile)
            }
            guard !sender.isEmpty, sender == senderKey(other.sender) else { return nil }
            if reference.count >= minimumReferenceLength, reference == referenceKey(other.reference) {
                return DuplicateMatch(existing: other, reason: .sameReference)
            }
            if let amount = candidate.amount, amount > 0, let otherAmount = other.amount, abs(amount - otherAmount) < 0.005,
               sameDate(candidate, other, calendar: calendar) {
                return DuplicateMatch(existing: other, reason: .sameSenderAmountAndDate)
            }
            return nil
        }
        return found.sorted { ($0.reason, $1.existing.filedAt) < ($1.reason, $0.existing.filedAt) }
    }

    /// Monthly bills from one sender often have the same amount, so the date must match too.
    static func sameDate(_ a: DuplicateFacts, _ b: DuplicateFacts, calendar: Calendar) -> Bool {
        if let first = a.documentDate, let second = b.documentDate {
            return calendar.isDate(first, inSameDayAs: second)
        }
        return abs(a.receivedDate.timeIntervalSince(b.receivedDate)) <= receivedDateTolerance
    }
}

extension DocumentRecord {
    public var duplicateFacts: DuplicateFacts {
        DuplicateFacts(
            id: id, relativePath: relativePath, contentHash: contentHash, sender: sender, amount: amount,
            reference: paymentReference, documentDate: documentDate, receivedDate: receivedDate, filedAt: filedAt
        )
    }
}
