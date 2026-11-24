import EventKit
import Foundation
import PaperTrailKit
import SwiftData

nonisolated enum BillReminderError: LocalizedError {
    case noAccess
    case noReminderAccount
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAccess:
            String(localized: "Paper Trail can't use Reminders. Allow full access for Paper Trail in Settings → Privacy & Security → Reminders, then tap Create Reminder on the bill.")
        case .noReminderAccount:
            String(localized: "There is no Reminders account to create the To pay list in. Turn on Reminders in iCloud settings, then try again.")
        case .saveFailed(let reason):
            String(localized: "Could not save the reminder: \(reason) Try again from Open Bills.")
        }
    }
}

/// What the app needs from Reminders, so tests can use a fake.
protocol BillReminding {
    /// Creates a reminder in the owner's To pay list and returns its external identifier.
    func createReminder(for bill: DocumentRecord) async throws -> String
    /// Completion dates of the reminders that are completed, by external identifier.
    func completedReminders(among externalIDs: [String]) async throws -> [String: Date]
    func completeReminder(externalID: String) async throws
    /// False when the reminder was deleted (or lives in an account this device can't see).
    func reminderExists(externalID: String) async -> Bool
    /// Removes the reminder (Clear All Documents, or an edited document that is no longer a bill).
    func deleteReminder(externalID: String) async throws
}

/// Apple Reminders via EventKit. Each owner has a list "To pay – <Owner>".
final class EventKitBillReminders: BillReminding {
    private let store = EKEventStore()

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            guard try await store.requestFullAccessToReminders() else { throw BillReminderError.noAccess }
        default:
            throw BillReminderError.noAccess
        }
    }

    /// The account for the To pay lists: iCloud when available. Exchange is avoided because
    /// its reminder identifiers differ per device, so paid state would not sync.
    private func reminderSource() throws -> EKSource {
        let withReminders = store.sources.filter { !$0.calendars(for: .reminder).isEmpty }
        if let iCloud = withReminders.first(where: { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveCompare("iCloud") == .orderedSame }) {
            return iCloud
        }
        if let calDAV = withReminders.first(where: { $0.sourceType == .calDAV }) { return calDAV }
        if let fallback = store.defaultCalendarForNewReminders()?.source, fallback.sourceType != .exchange { return fallback }
        if let local = store.sources.first(where: { $0.sourceType == .local }) { return local }
        guard let any = store.defaultCalendarForNewReminders()?.source else { throw BillReminderError.noReminderAccount }
        return any
    }

    private func list(for owner: String) throws -> EKCalendar {
        let name = BillReminderText.listName(owner: owner)
        let source = try reminderSource()
        if let existing = source.calendars(for: .reminder).first(where: { $0.title == name }) {
            return existing
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = name
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw BillReminderError.saveFailed(error.localizedDescription)
        }
        return calendar
    }

    func createReminder(for bill: DocumentRecord) async throws -> String {
        try await ensureAccess()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try list(for: bill.ownerName)
        reminder.title = BillReminderText.title(sender: bill.sender, amount: bill.amount)
        reminder.notes = BillReminderText.notes(amount: bill.amount, iban: bill.iban, reference: bill.paymentReference, relativePath: bill.relativePath)
        reminder.url = bill.billURL
        if let due = bill.dueDate {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = .current
            var components = gregorian.dateComponents([.year, .month, .day], from: due)
            components.calendar = gregorian
            reminder.dueDateComponents = components
            // A nudge two days before the due date, at 9:00, if that is still ahead.
            if let dayStart = gregorian.date(from: components),
               let alarmDate = gregorian.date(byAdding: DateComponents(day: -2, hour: 9), to: dayStart),
               alarmDate > .now {
                reminder.addAlarm(EKAlarm(absoluteDate: alarmDate))
            }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw BillReminderError.saveFailed(error.localizedDescription)
        }
        return reminder.calendarItemExternalIdentifier
    }

    private func reminders(withExternalID id: String) -> [EKReminder] {
        store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKReminder }
    }

    func completedReminders(among externalIDs: [String]) async throws -> [String: Date] {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [:] }
        var completed: [String: Date] = [:]
        for id in externalIDs {
            if let done = reminders(withExternalID: id).first(where: \.isCompleted) {
                completed[id] = done.completionDate ?? .now
            }
        }
        return completed
    }

    func reminderExists(externalID: String) async -> Bool {
        // Without access we can't tell; assume it exists so nothing is created twice.
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return true }
        return !reminders(withExternalID: externalID).isEmpty
    }

    func deleteReminder(externalID: String) async throws {
        try await ensureAccess()
        for reminder in reminders(withExternalID: externalID) {
            do {
                try store.remove(reminder, commit: true)
            } catch {
                throw BillReminderError.saveFailed(error.localizedDescription)
            }
        }
    }

    func completeReminder(externalID: String) async throws {
        try await ensureAccess()
        for reminder in reminders(withExternalID: externalID) where !reminder.isCompleted {
            reminder.isCompleted = true
            do {
                try store.save(reminder, commit: true)
            } catch {
                throw BillReminderError.saveFailed(error.localizedDescription)
            }
        }
    }
}

/// Keeps bills and their reminders in step. Paid has one source of truth: the reminder.
struct BillService {
    var reminders: any BillReminding

    /// Creates the reminder for a newly filed unpaid bill. Filing itself already succeeded.
    func addReminder(for bill: DocumentRecord, context: ModelContextSaving) async throws {
        guard bill.isOpenBill, bill.reminderExternalID == nil else { return }
        bill.reminderExternalID = try await reminders.createReminder(for: bill)
        try context.save()
    }

    /// Creates a new reminder for a bill whose reminder was deleted, e.g. after removing an
    /// old To pay list. Only on the user's request, so nothing is ever duplicated silently.
    func recreateReminder(for bill: DocumentRecord, context: ModelContextSaving) async throws {
        guard bill.isOpenBill else { return }
        bill.reminderExternalID = try await reminders.createReminder(for: bill)
        try context.save()
    }

    /// After a document's details were edited: adds, replaces or removes its reminder. A new
    /// reminder is made before the old one is removed, so a failure never leaves the bill without one.
    func updateReminder(for bill: DocumentRecord, change: DocumentEdit.ReminderChange, context: ModelContextSaving) async throws {
        switch change {
        case .keep:
            return
        case .create:
            guard bill.isOpenBill else { return }
            bill.reminderExternalID = try await reminders.createReminder(for: bill)
            try context.save()
        case .replace:
            let old = bill.reminderExternalID
            bill.reminderExternalID = try await reminders.createReminder(for: bill)
            try context.save()
            if let old { try await reminders.deleteReminder(externalID: old) }
        case .remove:
            if let old = bill.reminderExternalID { try await reminders.deleteReminder(externalID: old) }
            bill.reminderExternalID = nil
            try context.save()
        }
    }

    func reminderIsMissing(for bill: DocumentRecord) async -> Bool {
        guard let id = bill.reminderExternalID else { return false }
        return await !reminders.reminderExists(externalID: id)
    }

    /// Marks bills paid whose reminder was completed (on any device).
    func syncPaidState(bills: [DocumentRecord], context: ModelContextSaving) async throws {
        let open = bills.filter { $0.isOpenBill && $0.reminderExternalID != nil }
        guard !open.isEmpty else { return }
        let completed = try await reminders.completedReminders(among: open.compactMap(\.reminderExternalID))
        var changed = false
        for bill in open {
            if let id = bill.reminderExternalID, let date = completed[id] {
                bill.isPaid = true
                bill.paidAt = date
                changed = true
            }
        }
        if changed { try context.save() }
    }

    /// "Mark as paid" in the app completes the reminder too, so both stay the same.
    func markPaid(_ bill: DocumentRecord, context: ModelContextSaving) async throws {
        if let id = bill.reminderExternalID {
            try await reminders.completeReminder(externalID: id)
        }
        bill.isPaid = true
        bill.paidAt = .now
        try context.save()
    }
}

/// The part of ModelContext that BillService uses.
protocol ModelContextSaving {
    func save() throws
}

extension ModelContext: ModelContextSaving {}
