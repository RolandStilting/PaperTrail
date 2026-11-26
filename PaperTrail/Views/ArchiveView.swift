import PaperTrailKit
import QuickLook
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
    @FocusState private var searchFocused: Bool
    @State private var selection: UUID?
    @State private var quickLookURL: URL?

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
            let haystack = [record.sender, record.documentDescription, record.categoryName, record.ownerName, record.ledgerCode, record.ledgerDescription,
                            record.extractedText ?? ""]
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
        // Wide (Mac, iPad): the list with the selected document beside it. Narrow: tap to open.
        ListWithDetail { split in
            documentList(split: split)
        } detail: {
            if let selection, shown.contains(where: { $0.id == selection }) {
                DocumentDetailView(id: selection, embedded: true)
                    .id(selection)
            } else {
                ContentUnavailableView("Select a document", systemImage: "doc.text.magnifyingglass",
                                       description: Text("Its PDF and details appear here."))
            }
        }
        .searchable(text: $search, prompt: Text("Sender, description or text"))
        .searchFocused($searchFocused)
        .onChange(of: model.wantsSearchFocus) { _, _ in takeSearchFocus() }
        .onAppear(perform: takeSearchFocus)
        .navigationTitle(owner ?? String(localized: "Archive"))
        .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu() } }
        .navigationDestination(for: DocumentRoute.self) { route in
            DocumentDetailView(id: route.id)
        }
        .quickLookPreview($quickLookURL)
    }

    /// The documents, grouped by month. In the split layout a row selects; otherwise it opens.
    private func documentList(split: Bool) -> some View {
        List(selection: $selection) {
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
                        Group {
                            if split {
                                DocumentRow(record: record, showsOwner: owner == nil, fileURL: model.fileURL(for: record))
                            } else {
                                NavigationLink(value: DocumentRoute(id: record.id)) {
                                    DocumentRow(record: record, showsOwner: owner == nil, fileURL: model.fileURL(for: record))
                                }
                            }
                        }
                        .tag(record.id)
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
        .arrowKeySelection($selection, in: months.flatMap { $0.records.map(\.id) })
        .onAppear { if split, selection == nil { selection = months.first?.records.first?.id } }
        // Space bar: a large Quick Look preview of the selected document, as in Finder.
        .onKeyPress(.space) {
            guard let selection, let record = shown.first(where: { $0.id == selection }),
                  let url = model.fileURL(for: record) else { return .ignored }
            quickLookURL = quickLookURL == nil ? url : nil
            return .handled
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if owner == nil {
                    FilterChip(title: ownerFilter.map { LocalizedStringKey($0) } ?? "Owner", isActive: ownerFilter != nil) {
                        Button("All Owners") { ownerFilter = nil }
                        ForEach(settingsStore.settings.owners) { o in
                            Button {
                                ownerFilter = o.name
                            } label: {
                                Label { Text(o.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(settingsStore.settings.color(ofOwner: o.name).color) }
                            }
                        }
                    }
                }
                FilterChip(title: categoryFilter.map { LocalizedStringKey($0) } ?? "Category", isActive: categoryFilter != nil) {
                    Button("All Categories") { categoryFilter = nil }
                    ForEach(settingsStore.settings.categories) { c in
                        Button(c.name, systemImage: CategoryStyle.symbol(for: c.name)) { categoryFilter = c.name }
                    }
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

    /// Find (⌘F): the cursor goes to the search field once.
    private func takeSearchFocus() {
        guard model.wantsSearchFocus else { return }
        model.wantsSearchFocus = false
        searchFocused = true
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
    @Environment(MailIntakeService.self) private var mail
    @State private var selection: URL?
    @State private var deleting: ReviewItem?

    private var ids: [URL] { model.reviewItems.map(\.url) }

    var body: some View {
        ListWithDetail { split in
            reviewList(split: split)
        } detail: {
            if let selection, let item = model.reviewItems.first(where: { $0.url == selection }) {
                ReviewPane(item: item) { filed in advance(after: item, filed: filed) }
                    .id(item.url)
            } else {
                ContentUnavailableView(model.reviewItems.isEmpty ? "All caught up" : "Select a document",
                                       systemImage: model.reviewItems.isEmpty ? "checkmark.circle" : "doc.text.magnifyingglass",
                                       description: Text(model.reviewItems.isEmpty ? "Nothing waiting to be filed." : "File it right here."))
            }
        }
        .navigationTitle("Needs Review")
        .refreshable {
            // Pull to refresh also checks the mailbox (the iPhone's main way to get new mail).
            await mail.checkNow()
            await model.refreshReviewItems()
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { AddDocumentMenu() } }
    }

    private func reviewList(split: Bool) -> some View {
        List(selection: $selection) {
            if model.reviewItems.isEmpty {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text("Shared, emailed and Inbox documents wait here until you file them."))
            }
            ForEach(model.reviewItems) { item in
                Group {
                    if split {
                        ReviewRow(item: item)
                    } else {
                        Button { Task { await model.openReviewItem(item) } } label: { ReviewRow(item: item) }
                            .disabled(model.isPreparing)
                    }
                }
                .tag(item.url)
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                }
            }
        }
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\"?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { item in
            Button("Move to Trash", role: .destructive) {
                Task { await model.deleteReviewItem(at: item.url) }
            }
        } message: { _ in
            Text("It's removed from Needs Review on all your devices. You can get it back from the Trash (Recently Deleted in Files).")
        }
        .arrowKeySelection($selection, in: ids)
        .onAppear { if split, selection == nil { selection = ids.first } }
        .onChange(of: ids) { _, newIDs in
            if split, let selection, !newIDs.contains(selection) { self.selection = newIDs.first }
        }
    }

    /// After filing, the next document is selected, so the queue can be worked through.
    private func advance(after item: ReviewItem, filed: Bool) {
        guard filed else { return }
        let index = ids.firstIndex(of: item.url) ?? 0
        Task {
            await model.refreshReviewItems()
            let remaining = ids
            selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
        }
    }
}

private struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
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
}

/// The filing screen for one Needs Review document, beside the list.
private struct ReviewPane: View {
    let item: ReviewItem
    var onFinished: (_ filed: Bool) -> Void

    @Environment(AppModel.self) private var model
    @State private var document: PendingDocument?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let document {
                FilingView(document: document, filingService: model.filingService, billService: model.billService,
                           embedded: true) { onFinished(true) }
            } else if let loadError {
                ContentUnavailableView("Can't open the document", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView("Opening…")
            }
        }
        .task {
            do { document = try await model.filingService.reviewQueue.open(item) } catch { loadError = error.localizedDescription }
        }
    }
}

/// A filed document in a list.
struct DocumentRow: View {
    let record: DocumentRecord
    var showsOwner = true
    var fileURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            DocumentThumbnail(url: fileURL, placeholderSymbol: CategoryStyle.symbol(for: record.categoryName))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sender).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    if showsOwner { OwnerDot(owner: record.ownerName) }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
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
        case .submitted: return ("Claimed", .accentColor)
        case .reimbursed: return ("Reimbursed", .done)
        case .none: break
        }
        if record.isUnpaidBill && record.isPaid { return ("Paid", .done) }
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
