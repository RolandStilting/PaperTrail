import PaperTrailKit
import SwiftData
import SwiftUI

/// The user confirms owner, category, dates, sender and description, then files the document.
struct FilingView: View {
    let document: PendingDocument
    let filingService: FilingService
    var onDone: () -> Void

    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.modelContext) private var modelContext

    @State private var ownerName = ""
    @State private var categoryName = ""
    @State private var receivedDate = Date.now
    @State private var hasDocumentDate = false
    @State private var documentDate = Date.now
    @State private var sender = ""
    @State private var descriptionText = ""

    @State private var extractedText: String?
    @State private var ocrFailed = false
    @State private var isFiling = false
    @State private var errorMessage: String?

    private var request: FilingRequest {
        FilingRequest(
            owner: ownerName, category: categoryName, receivedDate: receivedDate,
            documentDate: hasDocumentDate ? documentDate : nil, sender: sender, description: descriptionText
        )
    }

    private var previewPath: String? {
        try? FilingPlanner.plan(for: request, namer: filingService.namer).relativePath
    }

    var body: some View {
        Form {
            Section {
                PDFPreview(data: document.pdfData)
                    .frame(minHeight: 260)
            }

            Section("Where") {
                Picker("Owner", selection: $ownerName) {
                    ForEach(settingsStore.settings.owners) { Text($0.name).tag($0.name) }
                }
                Picker("Category", selection: $categoryName) {
                    ForEach(settingsStore.settings.categories) { Text($0.name).tag($0.name) }
                }
            }

            Section("Details") {
                DatePicker("Received", selection: $receivedDate, displayedComponents: .date)
                Toggle("Date on document", isOn: $hasDocumentDate)
                if hasDocumentDate {
                    DatePicker("Document date", selection: $documentDate, displayedComponents: .date)
                }
                TextField("Sender", text: $sender, prompt: Text("e.g. Acme Energy"))
                TextField("Description", text: $descriptionText, prompt: Text("At most 6 words"))
            }

            Section("File name") {
                if let previewPath {
                    Text(previewPath)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Choose an owner and a category.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recognised text") {
                if let extractedText {
                    DisclosureGroup(extractedText.isEmpty ? "No text found" : "Show text") {
                        Text(extractedText)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    .disabled(extractedText.isEmpty)
                } else if ocrFailed {
                    Text("Text recognition failed. You can still file the document.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        ProgressView()
                        Text("Recognising text…")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("File document")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDone)
                    .disabled(isFiling)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isFiling {
                    ProgressView()
                } else {
                    Button("File") { Task { await file() } }
                        .disabled(previewPath == nil)
                }
            }
        }
        .alert("Could not file the document", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .interactiveDismissDisabled(isFiling)
        .onAppear(perform: applyDefaults)
        .task { await recognizeText() }
    }

    private func applyDefaults() {
        if ownerName.isEmpty { ownerName = settingsStore.settings.owners.first?.name ?? "" }
        if categoryName.isEmpty { categoryName = settingsStore.settings.categories.first?.name ?? "" }
    }

    private func recognizeText() async {
        let recognizer = VisionTextRecognizer()
        do {
            if document.pageImages.isEmpty {
                extractedText = try await PDFTextExtractor(recognizer: recognizer).extractText(from: document.pdfData)
            } else {
                extractedText = try await recognizer.recognizeText(in: document.pageImages)
            }
        } catch is CancellationError {
            return
        } catch {
            ocrFailed = true
        }
    }

    private func file() async {
        isFiling = true
        defer { isFiling = false }
        do {
            _ = try await filingService.file(document, request: request, extractedText: extractedText, context: modelContext)
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
