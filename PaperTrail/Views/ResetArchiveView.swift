#if os(macOS)
import PaperTrailKit
import SwiftData
import SwiftUI

/// Clear All Documents: start over after testing. Settings stay.
struct ResetArchiveView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var options = ArchiveResetOptions()
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var result: String?

    private static let word = "CLEAR"

    var body: some View {
        Form {
            Section {
                Label("All documents in Paper Trail in iCloud Drive (every owner, Inbox and Needs Review) move to the Trash on this Mac.", systemImage: "trash")
                Label("The document list, bills and expense claims are cleared on all your devices.", systemImage: "list.bullet")
                Label("Kept: owners, categories, payment and email settings. Emails in your mailbox are not touched.", systemImage: "checkmark.shield")
            } header: {
                Text("What happens")
            } footer: {
                Text("You can put files back from the Trash; deleted iCloud Drive files can usually also be recovered for a while on iCloud.com. Empty the Trash only when you're sure.")
            }

            Section {
                Toggle("Also forget learned rules", isOn: $options.forgetRules)
                Toggle("Also delete the bills' reminders", isOn: $options.deleteReminders)
            }

            Section {
                TextField("Type \(Self.word) to confirm", text: $confirmation)
                    .autocorrectionDisabled()
                Button("Clear All Documents", role: .destructive) { Task { await clear() } }
                    .disabled(confirmation != Self.word || isWorking)
            }

            if let result {
                Section { Text(result) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clear All Documents")
    }

    private func clear() async {
        isWorking = true
        defer { isWorking = false }
        let reset = ArchiveReset(location: ICloudArchiveLocation(), reminders: EventKitBillReminders())
        do {
            let report = try await reset.run(options: options, context: modelContext)
            var text = String(localized: "Done: \(report.trashedItems) folders moved to the Trash, \(report.clearedDocuments) documents cleared from the list.")
            if !report.reminderProblems.isEmpty {
                text += " " + String(localized: "Some reminders could not be deleted; remove them in Reminders: \(report.reminderProblems.joined(separator: " "))")
            }
            result = text
            confirmation = ""
        } catch {
            result = error.localizedDescription
        }
    }
}
#endif
