import PaperTrailKit
import SwiftData
import SwiftUI

/// What needs attention now: documents to review, bills to pay, expenses to claim, VAT, and
/// what was filed recently. Every card leads to the screen where it gets done.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    #if os(macOS)
    @Environment(MailIntakeService.self) private var mail
    #endif
    @Query(filter: #Predicate<DocumentRecord> { $0.isUnpaidBill && !$0.isPaid }) private var openBills: [DocumentRecord]
    @Query(filter: #Predicate<DocumentRecord> { $0.reimbursedBy != nil && $0.claimID == nil }) private var openExpenses: [DocumentRecord]
    @Query(sort: \DocumentRecord.filedAt, order: .reverse) private var recent: [DocumentRecord]
    @Query private var allDocuments: [DocumentRecord]

    private var startOfToday: Date { Calendar.current.startOfDay(for: .now) }
    private var overdue: [DocumentRecord] { openBills.filter { ($0.dueDate ?? .distantFuture) < startOfToday } }
    private var dueSoon: [DocumentRecord] {
        let limit = Calendar.current.date(byAdding: .day, value: 7, to: startOfToday)!
        return openBills.filter { guard let due = $0.dueDate else { return false }; return due >= startOfToday && due < limit }
    }
    private func sum(_ records: [DocumentRecord]) -> Double { records.compactMap(\.amount).reduce(0, +) }

    static func count(_ n: Int, one: String, other: String) -> String { n == 1 ? one : other }

    /// VAT to reclaim in the current period, for each company that files VAT returns.
    private var vatNow: [(company: String, period: VATPeriod, total: Double)] {
        settingsStore.settings.owners.compactMap { owner in
            guard let kind = owner.vatPeriod else { return nil }
            let period = VATPeriod.containing(.now, kind: kind)
            let total = allDocuments
                .filter { ($0.ownerName == owner.name || $0.reimbursedBy == owner.name) && period.contains($0.vatDate) }
                .compactMap(\.vatInfo).filter { !$0.isForeign && !$0.isReverseCharge }
                .map(\.total).reduce(0, +)
            return (owner.name, period, total)
        }
    }

    /// Open bills by due date; bills without a due date last.
    private var upcomingBills: [DocumentRecord] {
        openBills.sorted { ($0.dueDate ?? .distantFuture, $0.receivedDate) < ($1.dueDate ?? .distantFuture, $1.receivedDate) }
    }

    private var startOfMonth: Date { Calendar.current.dateInterval(of: .month, for: .now)?.start ?? startOfToday }
    private var receivedThisMonth: [DocumentRecord] { allDocuments.filter { $0.receivedDate >= startOfMonth } }

    /// Amounts on documents received this month, per owner in settings order.
    private var monthTotals: [(owner: String, total: Double, count: Int)] {
        let documents = receivedThisMonth
        let configured = settingsStore.settings.owners.map(\.name)
        let used = Set(documents.map(\.ownerName))
        return (configured.filter(used.contains) + used.subtracting(configured).sorted()).map { owner in
            let mine = documents.filter { $0.ownerName == owner }
            return (owner, sum(mine), mine.count)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                notices
                quickActions
                cards
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    dueSoonPanel
                    thisMonthPanel
                }
                recentSection
            }
            .padding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Today")
        .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu() } }
        .refreshable { await model.refreshReviewItems() }
        .navigationDestination(for: DocumentRoute.self) { route in
            DocumentDetailView(id: route.id)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if model.archiveRoot?.isLocalFallback == true {
            Label("iCloud Drive is not available. This debug build is saving to a local folder.", systemImage: "exclamationmark.icloud")
                .foregroundStyle(.orange)
        }
        if !model.unreadableInboxFiles.isEmpty {
            Label("\(model.unreadableInboxFiles.count) files in the Inbox folder can't be read. Paper Trail reads PDFs and images only.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private var cards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            NavigationLink { ReviewListView() } label: {
                TodayCard(title: "Needs Review", systemImage: model.reviewItems.isEmpty ? "checkmark" : "tray.and.arrow.down",
                          tint: model.reviewItems.isEmpty ? .done : .accentColor,
                          value: "\(model.reviewItems.count)",
                          detail: model.reviewItems.isEmpty ? String(localized: "All caught up") : String(localized: "Waiting for you to file"))
            }
            NavigationLink { OpenBillsView(billService: model.billService, embedded: true) } label: {
                TodayCard(title: "To Pay", systemImage: "eurosign", tint: openBills.isEmpty ? .done : (overdue.isEmpty ? .orange : .red),
                          value: BillReminderText.amount(sum(openBills)),
                          detail: overdue.isEmpty
                            ? (dueSoon.isEmpty ? Self.count(openBills.count, one: String(localized: "1 open bill"), other: String(localized: "\(openBills.count) open bills")) : String(localized: "\(dueSoon.count) due this week"))
                            : String(localized: "\(overdue.count) overdue"))
            }
            NavigationLink { ExpensesView(expenseService: model.expenseService, embedded: true) } label: {
                TodayCard(title: "To Claim", systemImage: "arrow.uturn.backward", tint: openExpenses.isEmpty ? .done : .teal,
                          value: BillReminderText.amount(sum(openExpenses)),
                          detail: Self.count(openExpenses.count, one: String(localized: "1 expense"), other: String(localized: "\(openExpenses.count) expenses")))
            }
            ForEach(vatNow, id: \.company) { vat in
                NavigationLink { VATOverviewView(embedded: true) } label: {
                    TodayCard(title: "VAT \(vat.company)", systemImage: "percent", tint: .purple,
                              value: BillReminderText.amount(vat.total),
                              detail: Self.vatDetail(vat.period))
                }
            }
        }
        .buttonStyle(.plain)
    }

    static func vatDetail(_ period: VATPeriod) -> String {
        guard let deadline = period.usualDeadline() else { return String(localized: "\(period.label()) so far") }
        return String(localized: "\(period.label()) so far · return due \(deadline.formatted(.dateTime.day().month()))")
    }

    // MARK: Quick actions

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                #if os(iOS)
                if DocumentScannerView.isSupported {
                    QuickAction(title: "Scan", systemImage: "doc.viewfinder") { model.showingScanner = true }
                }
                #endif
                QuickAction(title: "Import", systemImage: "square.and.arrow.down") { model.showingImporter = true }
                #if os(macOS)
                if mail.status != .off {
                    QuickAction(title: mail.status == .checking ? "Checking…" : "Check Mail", systemImage: "envelope") {
                        Task { await mail.checkNow() }
                    }
                    .disabled(mail.status == .checking)
                }
                #endif
                if !model.reviewItems.isEmpty {
                    QuickAction(title: "Review \(model.reviewItems.count)", systemImage: "tray.and.arrow.down") {
                        if let first = model.reviewItems.first { Task { await model.openReviewItem(first) } }
                    }
                }
            }
        }
        .disabled(model.isPreparing)
    }

    // MARK: Due soon

    private var dueSoonPanel: some View {
        TodayPanel(title: "Due Soon", systemImage: "calendar") {
            if upcomingBills.isEmpty {
                Label("Nothing to pay", systemImage: "checkmark.seal")
                    .foregroundStyle(Color.done)
                    .padding(.vertical, 6)
            } else {
                ForEach(upcomingBills.prefix(5)) { bill in
                    NavigationLink { BillDetailView(bill: bill, billService: model.billService) } label: {
                        DueBillRow(bill: bill, startOfToday: startOfToday)
                    }
                    .buttonStyle(.plain)
                    if bill.id != upcomingBills.prefix(5).last?.id { Divider() }
                }
                if upcomingBills.count > 5 {
                    NavigationLink { OpenBillsView(billService: model.billService, embedded: true) } label: {
                        Text("All \(upcomingBills.count) open bills").font(.footnote)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: This month

    private var thisMonthPanel: some View {
        let totals = monthTotals
        return TodayPanel(title: LocalizedStringKey(Date.now.formatted(.dateTime.month(.wide).year())), systemImage: "chart.bar") {
            if totals.isEmpty {
                Text("Nothing received yet this month.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(BillReminderText.amount(totals.map(\.total).reduce(0, +)))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Text(Self.count(receivedThisMonth.count, one: String(localized: "1 document"), other: String(localized: "\(receivedThisMonth.count) documents")))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                let largest = max(totals.map(\.total).max() ?? 0, 0.01)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(totals, id: \.owner) { item in
                        GridRow {
                            Text(item.owner).font(.subheadline).lineLimit(1)
                            OwnerBar(fraction: item.total / largest, color: settingsStore.settings.color(ofOwner: item.owner).color)
                            Text(BillReminderText.amount(item.total))
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
                Text("Amounts on documents received this month, per owner.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if recent.isEmpty, model.reviewItems.isEmpty {
            ContentUnavailableView {
                Label("Start your archive", systemImage: "doc.text.viewfinder")
            } description: {
                Text("Scan or import a receipt, invoice or letter, or drop a file here.")
            } actions: {
                AddDocumentMenu().labelStyle(.titleAndIcon)
            }
        } else if !recent.isEmpty {
            Text("Recently filed").font(.headline).padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(recent.prefix(6)) { record in
                    NavigationLink(value: DocumentRoute(id: record.id)) {
                        DocumentRow(record: record, fileURL: model.fileURL(for: record))
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }
}

/// A large button in the row at the top of Today.
private struct QuickAction: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}

/// A horizontal bar for one owner's monthly total.
private struct OwnerBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(color)
                .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// A titled box on the Today screen, the same look as the cards.
private struct TodayPanel<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

/// A bill in Due Soon: owner, sender, due date and amount.
private struct DueBillRow: View {
    let bill: DocumentRecord
    let startOfToday: Date

    var body: some View {
        HStack(spacing: 10) {
            OwnerDot(owner: bill.ownerName)
            VStack(alignment: .leading, spacing: 1) {
                Text(bill.sender).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(dueText).font(.caption).foregroundStyle(dueColor)
            }
            Spacer()
            if let amount = bill.amount {
                Text(BillReminderText.amount(amount)).font(.subheadline).monospacedDigit()
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    private var dueText: String {
        guard let due = bill.dueDate else { return String(localized: "No due date") }
        let days = Calendar.current.dateComponents([.day], from: startOfToday, to: Calendar.current.startOfDay(for: due)).day ?? 0
        switch days {
        case ..<0: return String(localized: "Overdue since \(due.formatted(.dateTime.day().month()))")
        case 0: return String(localized: "Due today")
        case 1: return String(localized: "Due tomorrow")
        default: return String(localized: "Due \(due.formatted(.dateTime.weekday(.abbreviated).day().month()))")
        }
    }

    private var dueColor: Color {
        guard let due = bill.dueDate else { return .secondary }
        if due < startOfToday { return .red }
        return due < Calendar.current.date(byAdding: .day, value: 7, to: startOfToday)! ? .orange : .secondary
    }
}

/// One card on the Today screen.
struct TodayCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let value: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(tint)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .contentShape(.rect)
    }
}

/// Navigation value for a filed document.
struct DocumentRoute: Hashable, Identifiable {
    let id: UUID
}
