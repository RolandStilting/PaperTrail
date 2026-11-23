import PaperTrailKit
import SwiftData
import SwiftUI

/// What the archive shows besides owner and category.
enum ArchiveStatusFilter: String, CaseIterable, Identifiable {
    case all, toPay, paid, expenses, withVAT
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all: "Any status"
        case .toPay: "To pay"
        case .paid: "Paid"
        case .expenses: "Expenses"
        case .withVAT: "With VAT"
        }
    }

    func matches(_ record: DocumentRecord) -> Bool {
        switch self {
        case .all: true
        case .toPay: record.isOpenBill
        case .paid: record.isUnpaidBill && record.isPaid
        case .expenses: record.reimbursedBy != nil
        case .withVAT: !(record.vatInfo?.lines.isEmpty ?? true)
        }
    }
}

/// All filed documents (or one owner's), grouped by month, searchable and filterable.
struct ArchiveView: View {
    let owner: String?

    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DocumentRecord.receivedDate, order: .reverse) private var records: [DocumentRecord]
    @State private var search = ""
    @State private var ownerFilter: String?
    @State private var categoryFilter: String?
    @State private var yearFilter: Int?
    @State private var statusFilter = ArchiveStatusFilter.all

    private var calendar: Calendar { .current }

    private var inScope: [DocumentRecord] {
        guard let owner else { return records }
        return records.filter { $0.ownerName == owner }
    }

    private var shown: [DocumentRecord] {
        let terms = search.lowercased().split(separator: " ").map(String.init)
        return inScope.filter { record in
            if let ownerFilter, record.ownerName != ownerFilter { return false }
            if let categoryFilter, record.categoryName != categoryFilter { return false }
            if let yearFilter, calendar.component(.year, from: record.receivedDate) != yearFilter { return false }
            guard statusFilter.matches(record) else { return false }
            guard !terms.isEmpty else { return true }
            let haystack = [record.sender, record.documentDescription, record.categoryName, record.ownerName, record.extractedText ?? ""]
                .joined(separator: " ").lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    /// Months, newest first, each with its documents.
    private var months: [(month: Date, records: [DocumentRecord])] {
        let groups = Dictionary(grouping: shown) { calendar.dateInterval(of: .month, for: $0.receivedDate)?.start ?? $0.receivedDate }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    private var years: [Int] {
        Array(Set(inScope.map { calendar.component(.year, from: $0.receivedDate) })).sorted(by: >)
    }

    private var isFiltering: Bool {
        ownerFilter != nil || categoryFilter != nil || yearFilter != nil || statusFilter != .all
    }

    var body: some View {
        List {
            if shown.isEmpty {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if isFiltering {
                    ContentUnavailableView {
                        Label("No matching documents", systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button("Clear Filters") { clearFilters() }
                    }
                } else {
                    ContentUnavailableView("No documents yet", systemImage: "archivebox",
                                           description: Text("Documents you file appear here."))
                }
            }
            ForEach(months, id: \.month) { group in
                Section {
                    ForEach(group.records) { record in
                        NavigationLink(value: DocumentRoute(id: record.id)) {
                            DocumentRow(record: record, showsOwner: owner == nil, fileURL: model.fileURL(for: record))
                        }
                        .contextMenu { DocumentActions(record: record) }
                        .swipeActions(edge: .trailing) {
                            if record.isOpenBill {
                                Button("Paid", systemImage: "checkmark.circle") { markPaid(record) }
                                    .tint(.green)
                            }
                        }
                    }
                } header: {
                    Text(group.month.formatted(.dateTime.month(.wide).year()))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .searchable(text: $search, prompt: Text("Sender, description or text"))
        .navigationTitle(owner ?? String(localized: "Archive"))
        .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu() } }
        .navigationDestination(for: DocumentRoute.self) { route in
            DocumentDetailView(id: route.id)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if owner == nil {
                    FilterChip(title: ownerFilter.map { LocalizedStringKey($0) } ?? "Owner", isActive: ownerFilter != nil) {
                        Button("All Owners") { ownerFilter = nil }
                        ForEach(settingsStore.settings.owners) { o in Button(o.name) { ownerFilter = o.name } }
                    }
                }
                FilterChip(title: categoryFilter.map { LocalizedStringKey($0) } ?? "Category", isActive: categoryFilter != nil) {
                    Button("All Categories") { categoryFilter = nil }
                    ForEach(settingsStore.settings.categories) { c in Button(c.name) { categoryFilter = c.name } }
                }
                FilterChip(title: yearFilter.map { LocalizedStringKey(String($0)) } ?? "Year", isActive: yearFilter != nil) {
                    Button("All Years") { yearFilter = nil }
                    ForEach(years, id: \.self) { year in Button(String(year)) { yearFilter = year } }
                }
                FilterChip(title: statusFilter == .all ? "Status" : statusFilter.title, isActive: statusFilter != .all) {
                    ForEach(ArchiveStatusFilter.allCases) { status in Button(status.title) { statusFilter = status } }
                }
                if isFiltering {
                    Button("Clear", systemImage: "xmark.circle.fill") { clearFilters() }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func clearFilters() {
        ownerFilter = nil
        categoryFilter = nil
        yearFilter = nil
        statusFilter = .all
    }

    private func markPaid(_ record: DocumentRecord) {
        Task {
            do { try await model.billService.markPaid(record, context: modelContext) } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

/// A filter as a capsule with a menu of choices.
struct FilterChip<Choices: View>: View {
    let title: LocalizedStringKey
    let isActive: Bool
    @ViewBuilder var choices: Choices

    var body: some View {
        Menu {
            choices
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary), in: .capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Actions on a filed document, for context menus.
struct DocumentActions: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if record.isOpenBill {
            Button("Mark as Paid", systemImage: "checkmark.circle") {
                Task {
                    do { try await model.billService.markPaid(record, context: modelContext) } catch { model.errorMessage = error.localizedDescription }
                }
            }
        }
        ReimbursementMenu(record: record)
        if let url = model.fileURL(for: record) {
            ShareLink(item: url) { Label("Share PDF", systemImage: "square.and.arrow.up") }
        }
    }
}

/// Documents waiting in Needs Review.
struct ReviewListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if model.reviewItems.isEmpty {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text("Shared, emailed and Inbox documents wait here until you file them."))
            }
            ForEach(model.reviewItems) { item in
                Button { Task { await model.openReviewItem(item) } } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            if let date = item.savedDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: item.isDownloaded ? "doc.badge.clock" : "icloud.and.arrow.down")
                    }
                }
                .disabled(model.isPreparing)
            }
        }
        .navigationTitle("Needs Review")
        .refreshable { await model.refreshReviewItems() }
        .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu() } }
    }
}

/// A filed document in a list.
struct DocumentRow: View {
    let record: DocumentRecord
    var showsOwner = true
    var fileURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            DocumentThumbnail(url: fileURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sender).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let amount = record.amount { Text(BillReminderText.amount(amount)).monospacedDigit() }
                StatusBadge(record: record)
            }
        }
    }

    private var subtitle: String {
        let date = (record.documentDate ?? record.receivedDate).formatted(date: .abbreviated, time: .omitted)
        let place = showsOwner ? "\(record.ownerName) › \(record.categoryName)" : record.categoryName
        return "\(date) · \(place)"
    }
}

/// A small label for the document's state: to pay, paid, expense.
struct StatusBadge: View {
    let record: DocumentRecord

    var body: some View {
        if let (text, color) = status {
            Text(text)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(color)
                .background(color.opacity(0.15), in: .capsule)
        }
    }

    private var status: (LocalizedStringKey, Color)? {
        if record.isOpenBill {
            let overdue = (record.dueDate ?? .distantFuture) < Calendar.current.startOfDay(for: .now)
            return (overdue ? "Overdue" : "To pay", overdue ? .red : .orange)
        }
        switch record.claimState {
        case .open: return ("To claim", .teal)
        case .submitted: return ("Claimed", .blue)
        case .reimbursed: return ("Reimbursed", .green)
        case .none: break
        }
        if record.isUnpaidBill && record.isPaid { return ("Paid", .green) }
        return nil
    }
}

/// Context menu: mark a filed document as reimbursable by a company (not after it was claimed).
struct ReimbursementMenu: View {
    let record: DocumentRecord
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if record.claimID == nil {
            Menu("To Be Reimbursed By", systemImage: "eurosign.arrow.circlepath") {
                Button("Nobody") { model.setReimbursedBy(nil, on: record, context: modelContext) }
                ForEach(settingsStore.settings.owners.filter { $0.name != record.ownerName }) { owner in
                    Button(owner.name) { model.setReimbursedBy(owner.name, on: record, context: modelContext) }
                }
            }
        }
    }
}
