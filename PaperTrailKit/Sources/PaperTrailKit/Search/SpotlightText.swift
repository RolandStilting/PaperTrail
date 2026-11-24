import Foundation

/// What a filed document looks like in a Spotlight result.
public enum SpotlightText {
    /// "KPN – Mobile invoice March", or just the sender.
    public static func title(sender: String, description: String) -> String {
        let sender = sender.trimmingCharacters(in: .whitespaces)
        let description = description.trimmingCharacters(in: .whitespaces)
        if description.isEmpty { return sender }
        if sender.isEmpty { return description }
        return "\(sender) – \(description)"
    }

    /// "3 Mar 2026 · Private › Invoices · € 42,50".
    public static func summary(received: Date, owner: String, category: String, amount: Double?,
                               locale: Locale = .current, calendar: Calendar? = nil) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale)
        if let calendar {
            style.calendar = calendar
            style.timeZone = calendar.timeZone
        }
        var parts = [received.formatted(style), "\(owner) › \(category)"]
        if let amount { parts.append(BillReminderText.amount(amount, locale: locale)) }
        return parts.joined(separator: " · ")
    }

    /// Words Spotlight should match besides the title and text.
    public static func keywords(sender: String, owner: String, category: String, reference: String?) -> [String] {
        [sender, owner, category, reference ?? ""].filter { !$0.isEmpty }
    }
}
