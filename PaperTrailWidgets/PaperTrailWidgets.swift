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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
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
        let payTint: Color = overdue > 0 ? .red : (snapshot.openBillCount == 0 ? .done : .orange)
        switch family {
        case .systemMedium:
            // The three totals, then the bill that is due first.
            VStack(alignment: .leading, spacing: 8) {
                columns(snapshot, overdue: overdue, payTint: payTint, card: false)
                Divider()
                BillList(snapshot: snapshot, today: entry.date, limit: 1, large: false, showsMore: false)
                Spacer(minLength: 0)
            }
        case .systemLarge:
            VStack(alignment: .leading, spacing: 10) {
                columns(snapshot, overdue: overdue, payTint: payTint, card: true)
                if !snapshot.hidesDetails, !snapshot.bills.isEmpty {
                    Text("Next to pay").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                FittingBillList(snapshot: snapshot, today: entry.date, upTo: 4)
                Spacer(minLength: 0)
                PaidThisMonthStrip(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // Small: the total to pay, with review and claim underneath.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    IconBadge(systemImage: "eurosign", tint: payTint, size: 36)
                    Spacer()
                    if overdue > 0 {
                        Text("\(overdue)")
                            .font(.caption.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.red, in: .capsule)
                    }
                }
                Spacer(minLength: 2)
                Text(Amount.text(snapshot.openBillTotal, count: snapshot.openBillCount))
                    .font(.title2.weight(.bold)).monospacedDigit()
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .privacySensitive()
                Text(overdue > 0 ? String(localized: "To pay · \(overdue) overdue") : String(localized: "To pay · \(snapshot.openBillCount) open"))
                    .font(.caption).foregroundStyle(overdue > 0 ? .red : .secondary)
                    .lineLimit(1)
                Divider().padding(.vertical, 2)
                HStack(spacing: 10) {
                    Label("\(snapshot.reviewCount)", systemImage: "tray.and.arrow.down.fill")
                        .foregroundStyle(snapshot.reviewCount == 0 ? Color.secondary : Color.brand)
                    Label(Amount.text(snapshot.expenseTotal, count: snapshot.expenseCount), systemImage: "arrow.uturn.backward")
                        .foregroundStyle(snapshot.expenseCount == 0 ? Color.secondary : Color.teal)
                        .privacySensitive()
                }
                .font(.caption2.weight(.medium))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(snapshot.reviewCount > 0 && snapshot.openBillCount == 0 ? WidgetLink.review : WidgetLink.toPay)
        }
    }

    private func columns(_ snapshot: WidgetSnapshot, overdue: Int, payTint: Color, card: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            OverviewColumn(title: "Review", value: "\(snapshot.reviewCount)", systemImage: "tray.and.arrow.down.fill",
                           tint: snapshot.reviewCount == 0 ? .done : Color.brand,
                           detail: snapshot.reviewCount == 0 ? String(localized: "All caught up") : String(localized: "to file"),
                           card: card, link: WidgetLink.review)
            OverviewColumn(title: "To Pay", value: Amount.text(snapshot.openBillTotal, count: snapshot.openBillCount),
                           systemImage: "eurosign", tint: payTint,
                           detail: overdue > 0 ? String(localized: "\(overdue) overdue") : String(localized: "\(snapshot.openBillCount) open"),
                           detailIsWarning: overdue > 0, card: card, link: WidgetLink.toPay)
            OverviewColumn(title: "To Claim", value: Amount.text(snapshot.expenseTotal, count: snapshot.expenseCount),
                           systemImage: "arrow.uturn.backward", tint: snapshot.expenseCount == 0 ? .done : .teal,
                           detail: snapshot.expenseCount == 1 ? String(localized: "1 expense") : String(localized: "\(snapshot.expenseCount) expenses"),
                           card: card, link: WidgetLink.expenses)
        }
    }
}

private struct OverviewColumn: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color
    let detail: String
    var detailIsWarning = false
    var card = false
    let link: URL

    var body: some View {
        Link(destination: link) {
            VStack(alignment: .leading, spacing: 3) {
                // Cards are narrower inside: the title goes under the icon there, so it isn't cut off.
                if card {
                    IconBadge(systemImage: systemImage, tint: tint, size: 30)
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1).padding(.top, 2)
                } else {
                    HStack(spacing: 6) {
                        IconBadge(systemImage: systemImage, tint: tint, size: 26)
                        Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.bottom, 2)
                }
                Text(value)
                    .font((card ? Font.title3 : .headline).weight(.bold)).monospacedDigit()
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .privacySensitive()
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(detailIsWarning ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(card ? 8 : 0)
            .background(card ? tint.opacity(0.1) : .clear, in: .rect(cornerRadius: 12))
        }
    }
}

/// As many bills as fit: large widgets are shorter on the Mac and smaller iPhones than on a Pro Max.
private struct FittingBillList: View {
    let snapshot: WidgetSnapshot
    let today: Date
    let upTo: Int

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach((1...upTo).reversed(), id: \.self) { limit in
                BillList(snapshot: snapshot, today: today, limit: limit, large: true, showsMore: true)
            }
        }
    }
}

/// Open bills, soonest due first, or a short line when there are none or details are hidden.
private struct BillList: View {
    let snapshot: WidgetSnapshot
    let today: Date
    let limit: Int
    let large: Bool
    let showsMore: Bool

    var body: some View {
        if snapshot.hidesDetails {
            HStack(spacing: 10) {
                IconBadge(systemImage: "lock.fill", tint: .secondary, size: large ? 32 : 26)
                Text("Open Paper Trail to see your bills.").font(.caption).foregroundStyle(.secondary)
            }
        } else if snapshot.bills.isEmpty {
            HStack(spacing: 10) {
                IconBadge(systemImage: "checkmark.seal.fill", tint: .done, size: large ? 32 : 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Nothing to pay").font(.subheadline.weight(.semibold))
                    Text("All bills are paid.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            let shown = Array(snapshot.bills.prefix(limit))
            VStack(alignment: .leading, spacing: large ? 8 : 5) {
                ForEach(shown) { bill in
                    Link(destination: WidgetLink.bill(bill.id)) {
                        BillRow(bill: bill, today: today, large: large)
                    }
                }
                if showsMore, snapshot.openBillCount > shown.count {
                    Text("+ \(snapshot.openBillCount - shown.count) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
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

    private var isLarge: Bool { family == .systemLarge }

    var body: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: isLarge ? 10 : 6) {
                header(snapshot)
                if isLarge, !snapshot.hidesDetails, snapshot.openBillCount > 0 {
                    summary(snapshot)
                }
                if snapshot.hidesDetails {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        IconBadge(systemImage: "lock.fill", tint: .secondary, size: 32)
                        Text("Open Paper Trail to see your bills.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                } else if snapshot.bills.isEmpty {
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        IconBadge(systemImage: "checkmark.seal.fill", tint: .done, size: isLarge ? 44 : 32)
                        VStack(alignment: .leading) {
                            Text("Nothing to pay").font(.headline)
                            Text("All bills are paid.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                } else {
                    if isLarge {
                        FittingBillList(snapshot: snapshot, today: entry.date, upTo: 4)
                    } else {
                        BillList(snapshot: snapshot, today: entry.date, limit: 2, large: false, showsMore: true)
                    }
                    Spacer(minLength: 0)
                }
                if isLarge {
                    PaidThisMonthStrip(snapshot: snapshot)
                    footer(snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(WidgetLink.toPay)
        } else {
            NotYetView()
        }
    }

    private func header(_ snapshot: WidgetSnapshot) -> some View {
        let overdue = snapshot.overdue(today: entry.date)
        return HStack(spacing: 10) {
            IconBadge(systemImage: "eurosign", tint: overdue > 0 ? .red : Color.brand, size: isLarge ? 40 : 30)
            VStack(alignment: .leading, spacing: 0) {
                Text("To Pay").font(isLarge ? .headline : .subheadline.weight(.semibold))
                Text(overdue > 0 ? String(localized: "\(snapshot.openBillCount) open · \(overdue) overdue")
                                 : String(localized: "\(snapshot.openBillCount) open"))
                    .font(.caption)
                    .foregroundStyle(overdue > 0 ? .red : .secondary)
            }
            Spacer()
            Text(Amount.text(snapshot.openBillTotal, count: snapshot.openBillCount))
                .font(isLarge ? .title.weight(.bold) : .title3.weight(.bold)).monospacedDigit()
                .minimumScaleFactor(0.5).lineLimit(1)
                .privacySensitive()
        }
    }

    /// Overdue, due within a week, and later: where the money goes when.
    private func summary(_ snapshot: WidgetSnapshot) -> some View {
        let total = snapshot.openBillTotal ?? 0
        let overdue = snapshot.overdueTotal ?? 0
        let soon = snapshot.dueSoonTotal ?? 0
        return HStack(spacing: 8) {
            StatBox(title: "Overdue", value: BillReminderText.amount(overdue), tint: overdue > 0 ? .red : .secondary)
            StatBox(title: "Next 7 days", value: BillReminderText.amount(soon), tint: soon > 0 ? .orange : .secondary)
            StatBox(title: "Later", value: BillReminderText.amount(max(0, total - overdue - soon)), tint: Color.brand)
        }
    }

    /// Review and claim as two tiles, so the bottom of the large widget isn't just a line of text.
    private func footer(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 8) {
            FooterTile(systemImage: "tray.and.arrow.down.fill", tint: snapshot.reviewCount == 0 ? .done : Color.brand,
                       value: "\(snapshot.reviewCount)",
                       title: snapshot.reviewCount == 0 ? String(localized: "All caught up") : String(localized: "To review"),
                       link: WidgetLink.review)
            FooterTile(systemImage: "arrow.uturn.backward", tint: snapshot.expenseCount == 0 ? .done : .teal,
                       value: Amount.text(snapshot.expenseTotal, count: snapshot.expenseCount),
                       title: snapshot.expenseCount == 0 ? String(localized: "Nothing to claim")
                                                         : String(localized: "\(snapshot.expenseCount) to claim"),
                       link: WidgetLink.expenses)
        }
    }
}

private struct FooterTile: View {
    let systemImage: String
    let tint: Color
    let value: String
    let title: String
    let link: URL

    var body: some View {
        Link(destination: link) {
            HStack(spacing: 8) {
                IconBadge(systemImage: systemImage, tint: tint, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
                        .minimumScaleFactor(0.6).lineLimit(1).privacySensitive()
                    Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.1), in: .rect(cornerRadius: 12))
        }
    }
}

private struct BillRow: View {
    let bill: WidgetSnapshot.Bill
    let today: Date
    let large: Bool

    var body: some View {
        let overdue = bill.isOverdue(today: today)
        let soon = (0...7).contains(bill.daysUntilDue(today: today) ?? -1)
        HStack(spacing: 10) {
            // The sender's initial in the owner's colour, as in the archive.
            Text(String(bill.sender.prefix(1)).uppercased())
                .font((large ? Font.headline : .subheadline).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: large ? 34 : 26, height: large ? 34 : 26)
                .background(bill.ownerColor?.color ?? Color.brand, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(bill.sender).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(bill.dueText(today: today))
                        .foregroundStyle(overdue ? Color.red : (soon ? Color.orange : Color.secondary))
                    if large {
                        Text("· \(bill.owner)").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let amount = bill.amount {
                Text(BillReminderText.amount(amount))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
            }
        }
        .privacySensitive()
    }
}

// MARK: Shared

/// What's already done this month, so a short list still tells a full story.
private struct PaidThisMonthStrip: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if !snapshot.hidesDetails, let count = snapshot.paidThisMonthCount, let total = snapshot.paidThisMonthTotal {
            HStack(spacing: 10) {
                IconBadge(systemImage: "checkmark", tint: .done, size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Paid this month").font(.caption.weight(.semibold))
                    Text(count == 0 ? String(localized: "Nothing paid yet")
                                    : (count == 1 ? String(localized: "1 bill") : String(localized: "\(count) bills")))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(BillReminderText.amount(total))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(count == 0 ? Color.secondary : Color.done)
                    .privacySensitive()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.done.opacity(0.1), in: .rect(cornerRadius: 12))
        }
    }
}

/// A symbol in a softly tinted circle.
private struct IconBadge: View {
    let systemImage: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .circle)
    }
}

private struct StatBox: View {
    let title: LocalizedStringKey
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(tint)
                .minimumScaleFactor(0.6).lineLimit(1)
                .privacySensitive()
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
    }
}

private struct NotYetView: View {
    var body: some View {
        VStack(spacing: 8) {
            IconBadge(systemImage: "doc.text.magnifyingglass", tint: Color.brand, size: 40)
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

extension OwnerColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .gray: .gray
        }
    }
}

extension Color {
    static let done = Color("DoneColor")
    /// The app's navy; widgets don't take the accent colour automatically.
    static let brand = Color("AccentColor")
}
