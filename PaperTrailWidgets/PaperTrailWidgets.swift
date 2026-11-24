import PaperTrailKit
import SwiftUI
import WidgetKit

/// Paper Trail's widgets. They read the summary the app writes into the App Group
/// (`WidgetSnapshot`); nothing here opens the archive or leaves the device.
@main
struct PaperTrailWidgets: WidgetBundle {
    var body: some Widget {
        OverviewWidget()
        ToPayWidget()
    }
}

// MARK: Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil until the app has run once with the widget installed.
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // The widget gallery shows made-up content, never real amounts.
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .sample() : Self.current))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app reloads the widgets when something changes; overdue changes at midnight.
        let tomorrow = Calendar.current.startOfDay(for: .now.addingTimeInterval(24 * 60 * 60))
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: Self.current)], policy: .after(tomorrow)))
    }

    static var current: WidgetSnapshot? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: SharedIncoming.appGroupInfoKey) as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return WidgetSnapshot.read(from: container)
    }
}

// MARK: Overview

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "nl.papertrail.overview", provider: SnapshotProvider()) { entry in
            OverviewView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Paper Trail")
        .description("What needs attention: documents to file, bills to pay and expenses to claim.")
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}

struct OverviewView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
        } else {
            NotYetView()
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        let overdue = snapshot.overdue(today: entry.date)
        switch family {
        case .systemMedium:
            HStack(spacing: 10) {
                Tile(title: "Review", value: "\(snapshot.reviewCount)", systemImage: "tray.and.arrow.down",
                     tint: snapshot.reviewCount == 0 ? .done : Color.brand, link: WidgetLink.review)
                Tile(title: "To Pay", value: Amount.text(snapshot.openBillTotal, count: snapshot.openBillCount),
                     systemImage: "eurosign", tint: overdue > 0 ? .red : (snapshot.openBillCount == 0 ? .done : .orange),
                     detail: overdue > 0 ? String(localized: "\(overdue) overdue") : nil, link: WidgetLink.toPay)
                Tile(title: "To Claim", value: Amount.text(snapshot.expenseTotal, count: snapshot.expenseCount),
                     systemImage: "arrow.uturn.backward", tint: snapshot.expenseCount == 0 ? .done : .teal, link: WidgetLink.expenses)
            }
        #if os(iOS)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label("To Pay", systemImage: "eurosign.circle").font(.headline).widgetAccentable()
                Text(Amount.text(snapshot.openBillTotal, count: snapshot.openBillCount)).privacySensitive()
                Text(overdue > 0 ? String(localized: "\(overdue) overdue") : String(localized: "\(snapshot.reviewCount) to review"))
                    .foregroundStyle(.secondary)
            }
            .widgetURL(WidgetLink.toPay)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: overdue > 0 ? "exclamationmark.circle" : "eurosign")
                    Text("\(snapshot.openBillCount)").font(.title3.bold())
                }
            }
            .widgetURL(WidgetLink.toPay)
        case .accessoryInline:
            Text(overdue > 0 ? String(localized: "\(snapshot.openBillCount) to pay, \(overdue) overdue")
                             : String(localized: "\(snapshot.openBillCount) to pay"))
                .widgetURL(WidgetLink.toPay)
        #endif
        default:
            // Small: what most needs attention.
            VStack(alignment: .leading, spacing: 6) {
                Label("To Pay", systemImage: "eurosign.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(overdue > 0 ? .red : Color.brand)
                Text(Amount.text(snapshot.openBillTotal, count: snapshot.openBillCount))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .privacySensitive()
                if overdue > 0 {
                    Text("\(overdue) overdue").font(.caption).foregroundStyle(.red)
                } else {
                    Text("\(snapshot.openBillCount) open bills").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Label("\(snapshot.reviewCount) to review", systemImage: "tray.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(snapshot.reviewCount > 0 && snapshot.openBillCount == 0 ? WidgetLink.review : WidgetLink.toPay)
        }
    }
}

private struct Tile: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color
    var detail: String?
    let link: URL

    var body: some View {
        Link(destination: link) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(value)
                    .font(.headline).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .privacySensitive()
                Text(title).font(.caption).foregroundStyle(.secondary)
                // Every tile has this line, so the values line up across the widget.
                Text(detail ?? " ").font(.caption2).foregroundStyle(.red)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: To Pay

struct ToPayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "nl.papertrail.topay", provider: SnapshotProvider()) { entry in
            ToPayView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("To Pay")
        .description("Your open bills, the soonest due first. Tap one to see its payment code.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct ToPayView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("To Pay", systemImage: "eurosign.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color.brand)
                    Spacer()
                    Text(Amount.text(snapshot.openBillTotal, count: snapshot.openBillCount))
                        .font(.headline).monospacedDigit()
                        .privacySensitive()
                }
                if snapshot.hidesDetails {
                    Spacer()
                    Label("Open Paper Trail to see your bills.", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else if snapshot.bills.isEmpty {
                    Spacer()
                    Label("Nothing to pay", systemImage: "checkmark.seal")
                        .font(.callout).foregroundStyle(Color.done)
                    Spacer()
                } else {
                    let shown = snapshot.bills.prefix(family == .systemLarge ? WidgetSnapshot.maxBills : 3)
                    ForEach(shown) { bill in
                        Link(destination: WidgetLink.bill(bill.id)) { BillLine(bill: bill, today: entry.date) }
                        if bill.id != shown.last?.id { Divider() }
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(WidgetLink.toPay)
        } else {
            NotYetView()
        }
    }
}

private struct BillLine: View {
    let bill: WidgetSnapshot.Bill
    let today: Date

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(bill.sender).font(.subheadline.weight(.medium)).lineLimit(1)
                if let due = bill.dueDate {
                    Text(bill.isOverdue(today: today) ? String(localized: "Overdue since \(due.formatted(.dateTime.day().month()))")
                                                     : String(localized: "Due \(due.formatted(.dateTime.day().month()))"))
                        .font(.caption)
                        .foregroundStyle(bill.isOverdue(today: today) ? .red : .secondary)
                }
            }
            Spacer()
            if let amount = bill.amount {
                Text(BillReminderText.amount(amount)).font(.subheadline).monospacedDigit()
            }
        }
        .privacySensitive()
    }
}

// MARK: Shared

private struct NotYetView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(Color.brand)
            Text("Open Paper Trail once to show your documents here.")
                .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }
}

private enum Amount {
    /// The total, or the count when amounts are hidden (app lock on).
    static func text(_ total: Double?, count: Int) -> String {
        guard let total else { return String(localized: "\(count) open") }
        return BillReminderText.amount(total)
    }
}

extension Color {
    static let done = Color("DoneColor")
    /// The app's navy; widgets don't take the accent colour automatically.
    static let brand = Color("AccentColor")
}
