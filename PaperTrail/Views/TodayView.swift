import PaperTrailKit
import SwiftData
import SwiftUI

/// What needs attention now: documents to review, bills to pay, expenses to claim, VAT, and
/// what was filed recently. Every card leads to the screen where it gets done.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                notices
                cards
                recentSection
            }
            .padding()
            .frame(maxWidth: 760, alignment: .leading)
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
                TodayCard(title: "Needs Review", systemImage: "tray.and.arrow.down", tint: .blue,
                          value: "\(model.reviewItems.count)",
                          detail: model.reviewItems.isEmpty ? String(localized: "All caught up") : String(localized: "Waiting for you to file"))
            }
            NavigationLink { OpenBillsView(billService: model.billService, embedded: true) } label: {
                TodayCard(title: "To Pay", systemImage: "eurosign.circle", tint: overdue.isEmpty ? .orange : .red,
                          value: BillReminderText.amount(sum(openBills)),
                          detail: overdue.isEmpty
                            ? (dueSoon.isEmpty ? String(localized: "\(openBills.count) open bills") : String(localized: "\(dueSoon.count) due this week"))
                            : String(localized: "\(overdue.count) overdue"))
            }
            NavigationLink { ExpensesView(expenseService: model.expenseService, embedded: true) } label: {
                TodayCard(title: "To Claim", systemImage: "eurosign.arrow.circlepath", tint: .teal,
                          value: BillReminderText.amount(sum(openExpenses)),
                          detail: String(localized: "\(openExpenses.count) expenses"))
            }
            ForEach(vatNow, id: \.company) { vat in
                NavigationLink { VATOverviewView(embedded: true) } label: {
                    TodayCard(title: "VAT \(vat.company)", systemImage: "percent", tint: .purple,
                              value: BillReminderText.amount(vat.total),
                              detail: String(localized: "\(vat.period.label()) so far"))
                }
            }
        }
        .buttonStyle(.plain)
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
                        DocumentRow(record: record)
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

/// One card on the Today screen.
struct TodayCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .contentShape(.rect)
    }
}

/// Navigation value for a filed document.
struct DocumentRoute: Hashable {
    let id: UUID
}
