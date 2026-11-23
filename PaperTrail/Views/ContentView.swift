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

    var body: some View {
        NavigationStack {
            List {
                if archiveRoot?.isLocalFallback == true {
                    Label("iCloud Drive is not available. This debug build is saving to a local folder.", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                }
                if records.isEmpty {
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
        .task { await resolveArchive() }
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
