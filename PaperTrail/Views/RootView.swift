import EventKit
import PaperTrailKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Where the user is in the app. Tabs on iPhone; a sidebar on iPad and Mac.
enum Destination: Hashable {
    case today
    case review
    case archive(owner: String?)
    case toPay
    case expenses
    case vat
    case settings
}

/// The app's frame: layout per device, plus everything that works the same on every screen
/// (filing sheet, scanner, import, drag and drop, intake checks, links from reminders).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var selection: Destination? = .today
    @State private var isDropTargeted = false

    private var usesTabs: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if usesTabs { tabs } else { sidebarLayout }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.handleDrop(urls) }
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if model.isPreparing { ProgressView("Preparing document…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) }
        }
        .sheet(item: $model.pending) { document in
            NavigationStack {
                FilingView(document: document, filingService: model.filingService, billService: model.billService) { model.pending = nil }
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 680)
            #endif
        }
        .sheet(isPresented: $model.showingBillFromLink) {
            OpenBillsView(billService: model.billService, initialBillID: model.billToOpen)
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $model.showingScanner) {
            DocumentScannerView { result in
                model.showingScanner = false
                model.handleScan(result)
            }
            .ignoresSafeArea()
        }
        #endif
        .fileImporter(isPresented: $model.showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url): Task { await model.importFile(url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onOpenURL { model.handle(url: $0) }
        .task {
            await model.resolveArchive()
            await model.refreshReviewItems()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                await model.syncBills(context: modelContext)
            }
        }
        .onChange(of: model.pending == nil) { _, closed in
            if closed { Task { await model.refreshReviewItems() } }
        }
        .task(id: scenePhase) {
            // While the app is in front, look in Inbox and Needs Review every minute.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshReviewItems()
                await model.syncBills(context: modelContext)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: iPhone

    private var tabs: some View {
        TabView {
            Tab("Today", systemImage: "sun.max") {
                NavigationStack { TodayView() }
            }
            .badge(model.reviewItems.count)
            Tab("Archive", systemImage: "archivebox") {
                NavigationStack { ArchiveView(owner: nil) }
            }
            Tab("Money", systemImage: "eurosign.circle") {
                NavigationStack { MoneyView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView(embedded: true) }
            }
        }
    }

    // MARK: iPad and Mac

    private var sidebarLayout: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Today", systemImage: "sun.max").tag(Destination.today)
                Label("Needs Review", systemImage: "tray.and.arrow.down")
                    .badge(model.reviewItems.count)
                    .tag(Destination.review)
                Section("Archive") {
                    Label("All Documents", systemImage: "archivebox").tag(Destination.archive(owner: nil))
                    ForEach(settingsStore.settings.owners) { owner in
                        Label(owner.name, systemImage: "folder").tag(Destination.archive(owner: owner.name))
                    }
                }
                Section("Money") {
                    Label("To Pay", systemImage: "eurosign.circle").tag(Destination.toPay)
                    Label("Expenses", systemImage: "eurosign.arrow.circlepath").tag(Destination.expenses)
                    if settingsStore.settings.owners.contains(where: { $0.vatPeriod != nil }) {
                        Label("VAT", systemImage: "percent").tag(Destination.vat)
                    }
                }
                #if os(iOS)
                Label("Settings", systemImage: "gearshape").tag(Destination.settings)
                #endif
            }
            .navigationTitle("Paper Trail")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            #endif
        } detail: {
            NavigationStack {
                detail(for: selection ?? .today)
            }
            .id(selection)
        }
    }

    @ViewBuilder
    private func detail(for destination: Destination) -> some View {
        switch destination {
        case .today: TodayView()
        case .review: ReviewListView()
        case .archive(let owner): ArchiveView(owner: owner)
        case .toPay: OpenBillsView(billService: model.billService, embedded: true)
        case .expenses: ExpensesView(expenseService: model.expenseService, embedded: true)
        case .vat: VATOverviewView(embedded: true)
        case .settings: SettingsView(embedded: true)
        }
    }
}

/// The Add menu used on several screens.
struct AddDocumentMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu("Add", systemImage: "plus") {
            #if os(iOS)
            if DocumentScannerView.isSupported {
                Button("Scan Document", systemImage: "doc.viewfinder") { model.showingScanner = true }
            }
            #endif
            Button("Import File…", systemImage: "square.and.arrow.down") { model.showingImporter = true }
        }
        .disabled(model.isPreparing)
    }
}

/// iPhone: the money screens in one tab.
struct MoneyView: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        List {
            NavigationLink { OpenBillsView(billService: model.billService, embedded: true) } label: {
                Label("To Pay", systemImage: "eurosign.circle")
            }
            NavigationLink { ExpensesView(expenseService: model.expenseService, embedded: true) } label: {
                Label("Expenses", systemImage: "eurosign.arrow.circlepath")
            }
            if settingsStore.settings.owners.contains(where: { $0.vatPeriod != nil }) {
                NavigationLink { VATOverviewView(embedded: true) } label: {
                    Label("VAT", systemImage: "percent")
                }
            }
        }
        .navigationTitle("Money")
    }
}
