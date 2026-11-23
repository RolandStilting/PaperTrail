import PaperTrailKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let filingService: FilingService

    @Query(sort: \DocumentRecord.filedAt, order: .reverse) private var records: [DocumentRecord]

    @State private var pending: PendingDocument?
    @State private var showingScanner = false
    @State private var showingImporter = false
    @State private var showingSettings = false
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var archiveRoot: ArchiveRoot?
    @State private var reviewItems: [ReviewItem] = []
    @State private var isDropTargeted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if archiveRoot?.isLocalFallback == true {
                    Label("iCloud Drive is not available. This debug build is saving to a local folder.", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                }
                if !reviewItems.isEmpty {
                    Section("Needs Review") {
                        ForEach(reviewItems) { item in
                            Button { Task { await openReviewItem(item) } } label: {
                                Label {
                                    Text(item.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } icon: {
                                    Image(systemName: item.isDownloaded ? "doc.badge.clock" : "icloud.and.arrow.down")
                                }
                            }
                            .disabled(isPreparing)
                        }
                    }
                }
                if records.isEmpty && reviewItems.isEmpty {
                    ContentUnavailableView(
                        "No documents yet",
                        systemImage: "doc.text.viewfinder",
                        description: Text("Scan or import a receipt, invoice or letter to file it.")
                    )
                }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.sender) – \(record.documentDescription)")
                            .font(.headline)
                        Text(record.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .refreshable { await refreshReviewItems() }
            .dropDestination(for: URL.self) { urls, _ in
                Task { await handleDrop(urls) }
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
            .navigationTitle("Paper Trail")
            .toolbar { toolbarContent }
            .overlay {
                if isPreparing { ProgressView("Preparing document…") }
            }
        }
        .sheet(item: $pending) { document in
            NavigationStack {
                FilingView(document: document, filingService: filingService) { pending = nil }
            }
            #if os(macOS)
            .frame(minWidth: 520, minHeight: 640)
            #endif
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView() }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingScanner) {
            DocumentScannerView { result in
                showingScanner = false
                handleScan(result)
            }
            .ignoresSafeArea()
        }
        #endif
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url): Task { await importFile(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await resolveArchive()
            await refreshReviewItems()
        }
        .onChange(of: pending == nil) { _, closed in
            if closed { Task { await refreshReviewItems() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshReviewItems() } }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("Add", systemImage: "plus") {
                #if os(iOS)
                if DocumentScannerView.isSupported {
                    Button("Scan document", systemImage: "doc.viewfinder") { showingScanner = true }
                }
                #endif
                Button("Import file…", systemImage: "square.and.arrow.down") { showingImporter = true }
            }
            .disabled(isPreparing)
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Settings", systemImage: "gearshape") { showingSettings = true }
        }
    }

    private func resolveArchive() async {
        do {
            archiveRoot = try await filingService.location.resolveRoot()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshReviewItems() async {
        guard let root = archiveRoot?.url else { return }
        do {
            reviewItems = try await filingService.reviewQueue.items(root: root)
        } catch {
            errorMessage = String(localized: "Could not read the Needs Review folder: \(error.localizedDescription). Pull down to try again.")
        }
    }

    private func openReviewItem(_ item: ReviewItem) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            pending = try await filingService.reviewQueue.open(item)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One dropped file opens the filing screen; several go to Needs Review to file one by one.
    /// Every file is checked; the ones that can't be read are listed in one message.
    private func handleDrop(_ urls: [URL]) async {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty, !isPreparing, pending == nil else { return }
        isPreparing = true
        defer { isPreparing = false }

        if fileURLs.count == 1 {
            do {
                pending = try await DocumentCapture.fromFile(at: fileURLs[0])
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        var failures: [String] = []
        for url in fileURLs {
            do {
                let document = try await DocumentCapture.fromFile(at: url)
                try await filingService.saveForReview(document)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await refreshReviewItems()
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n\n")
        }
    }

    private func handleScan(_ result: Result<[CGImage], Error>?) {
        switch result {
        case nil:
            return
        case .failure(let error):
            errorMessage = String(localized: "Scanning failed: \(error.localizedDescription). Try again.")
        case .success(let pages):
            do {
                pending = try DocumentCapture.fromScan(pages)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importFile(_ url: URL) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            pending = try await DocumentCapture.fromFile(at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
