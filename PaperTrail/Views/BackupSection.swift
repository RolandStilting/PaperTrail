import PaperTrailKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings → Backup: the weekly index export, Export Now and Import.
struct BackupSection: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext

    @State private var lastExport = IndexBackup.lastExport
    @State private var isWorking = false
    @State private var message: String?
    @State private var choosingImport = false
    @State private var pendingImport: IndexImportPlan?
    #if os(macOS)
    @State private var exportFolder: URL?
    #endif

    var body: some View {
        Section {
            LabeledContent("Last export") {
                Text(lastExport.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "Not yet"))
            }
            Button("Export Index Now", systemImage: "square.and.arrow.up.on.square") { Task { await exportNow() } }
                .disabled(isWorking)
            #if os(macOS)
            if let exportFolder {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([exportFolder]) }
            }
            #endif
            Button("Import Index…", systemImage: "square.and.arrow.down.on.square") {
                choosingImport = true
            }
                .disabled(isWorking)
        } header: {
            Text("Backup")
        } footer: {
            Text("Every week Paper Trail writes everything that isn't in the PDFs (amounts, VAT, paid bills, expense claims, learned rules) to Paper Trail/Export in iCloud Drive, as JSON and as a CSV for Excel or Numbers. The last 8 weeks are kept in Export/Backups. Import adds back documents and records that are missing from the index; it never changes or removes anything.")
        }
        #if os(macOS)
        // The Mac Settings window has no other picker, so it uses its own.
        .fileImporter(isPresented: $choosingImport, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): Task { await planImport(url) }
            case .failure(let error): message = error.localizedDescription
            }
        }
        #else
        // A system document picker in a sheet: SwiftUI shows only one .fileImporter per
        // view chain, and the main view already has one for importing documents.
        .sheet(isPresented: $choosingImport) {
            JSONDocumentPicker { url in
                choosingImport = false
                if let url { Task { await planImport(url) } }
            }
            .ignoresSafeArea()
        }
        #endif
        .confirmationDialog("Import index?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
                            presenting: pendingImport) { plan in
            Button("Import") { applyImport(plan) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(Self.summary(of: plan))
        }
        .alert("Backup", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func exportNow() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let export = try IndexBackup.makeExport(context: modelContext, settings: settingsStore.settings)
            let folder = try await model.indexBackup.export(export)
            lastExport = export.exportedAt
            #if os(macOS)
            exportFolder = folder
            #endif
            message = String(localized: "Exported \(export.documents.count) documents to Paper Trail/Export in iCloud Drive.")
        } catch {
            message = error.localizedDescription
        }
    }

    private func planImport(_ url: URL) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let (_, plan) = try await model.indexBackup.plan(importing: url, context: modelContext)
            if plan.isEmpty {
                message = Self.summary(of: plan)
            } else {
                pendingImport = plan
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func applyImport(_ plan: IndexImportPlan) {
        do {
            try IndexBackup.apply(plan, context: modelContext)
            message = String(localized: "Imported. \(Self.summary(of: plan))")
        } catch {
            message = error.localizedDescription
        }
    }

    static func summary(of plan: IndexImportPlan) -> String {
        var parts: [String] = []
        if plan.isEmpty {
            parts.append(String(localized: "Nothing to add: everything in this export is already in the index."))
        } else {
            parts.append(String(localized: "Adds \(plan.documents.count) documents, \(plan.expenseClaims.count) expense claims, \(plan.vatReturns.count) submitted VAT periods and \(plan.senderRules.count) learned rules."))
        }
        if plan.documentsAlreadyThere > 0 {
            parts.append(String(localized: "\(plan.documentsAlreadyThere) documents are already in the index and stay as they are."))
        }
        if !plan.missingFiles.isEmpty {
            parts.append(String(localized: "\(plan.missingFiles.count) documents are skipped because their PDF is no longer in iCloud Drive."))
        }
        return parts.joined(separator: " ")
    }
}

#if os(iOS)
/// Picks one JSON file with the system document picker (as a copy, so no security scope is needed).
struct JSONDocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}
#endif
